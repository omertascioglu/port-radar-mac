import XCTest
@testable import DevPort

private enum ClientValidationResult: Sendable {
    case success
    case localError(LocalAIError)
    case unknownError
}

private enum SyntheticClientError: Error, Sendable {
    case failed
}

private struct OllamaClientSpySnapshot: Equatable, Sendable {
    let validationModelIDs: [String]
    let chatModelIDs: [String]
    let chatMessages: [[OllamaChatMessage]]
    let unloadModelIDs: [String]
}

private actor OllamaClientSpy: OllamaClientProtocol {
    private let validationResult: ClientValidationResult
    private var validationModelIDs: [String] = []
    private var chatModelIDs: [String] = []
    private var chatMessages: [[OllamaChatMessage]] = []
    private var unloadModelIDs: [String] = []
    private var pendingChats: [CheckedContinuation<String, any Error>] = []
    private var chatCountWaiters:
        [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(validationResult: ClientValidationResult = .success) {
        self.validationResult = validationResult
    }

    func version() async throws -> String { "test" }
    func localModels() async throws -> [OllamaModel] { [] }

    func validateLocalModel(_ id: String) async throws {
        validationModelIDs.append(id)
        switch validationResult {
        case .success:
            return
        case .localError(let error):
            throw error
        case .unknownError:
            throw SyntheticClientError.failed
        }
    }

    func chat(
        model: String,
        messages: [OllamaChatMessage]
    ) async throws -> String {
        chatModelIDs.append(model)
        chatMessages.append(messages)
        resumeChatCountWaiters()
        return try await withCheckedThrowingContinuation { continuation in
            pendingChats.append(continuation)
        }
    }

    func unload(model: String) async {
        unloadModelIDs.append(model)
    }

    func waitUntilChatCount(_ count: Int) async {
        guard chatMessages.count < count else { return }
        await withCheckedContinuation { continuation in
            chatCountWaiters.append((count, continuation))
        }
    }

    func completeNextChat(with result: Result<String, SyntheticClientError>) {
        guard !pendingChats.isEmpty else { return }
        pendingChats.removeFirst().resume(with: result)
    }

    func snapshot() -> OllamaClientSpySnapshot {
        .init(
            validationModelIDs: validationModelIDs,
            chatModelIDs: chatModelIDs,
            chatMessages: chatMessages,
            unloadModelIDs: unloadModelIDs
        )
    }

    private func resumeChatCountWaiters() {
        var remaining:
            [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in chatCountWaiters {
            if chatMessages.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        chatCountWaiters = remaining
    }
}

final class OllamaConversationTests: XCTestCase {
    private let modelID = "qwen3:4b"

    func testProviderAvailabilityRequiresNonemptySelectedModel() async {
        let client = OllamaClientSpy()
        let provider = OllamaProvider(client: client)

        let missing = await provider.availability(modelID: nil)
        let empty = await provider.availability(modelID: "")

        XCTAssertEqual(missing, .unavailable(.ollamaModelRequired))
        XCTAssertEqual(empty, .unavailable(.ollamaModelRequired))
        let snapshot = await client.snapshot()
        XCTAssertTrue(snapshot.validationModelIDs.isEmpty)
    }

    func testProviderAvailabilityValidatesAndPreservesLocalError() async {
        let client = OllamaClientSpy(
            validationResult: .localError(.remoteModelRejected)
        )
        let provider = OllamaProvider(client: client)

        let availability = await provider.availability(modelID: modelID)

        XCTAssertEqual(availability, .unavailable(.remoteModelRejected))
        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.validationModelIDs, [modelID])
    }

    func testProviderAvailabilityMapsUnknownFailureToBoundedError() async {
        let client = OllamaClientSpy(validationResult: .unknownError)
        let provider = OllamaProvider(client: client)

        let availability = await provider.availability(modelID: modelID)

        XCTAssertEqual(availability, .unavailable(.ollamaNotRunning))
        XCTAssertFalse(String(describing: availability).contains("failed"))
    }

    func testProviderRevalidatesChosenModelWhenCreatingConversation() async throws {
        let client = OllamaClientSpy()
        let provider = OllamaProvider(client: client)

        let conversation = try await provider.makeConversation(
            context: .init(text: "port: 3000"),
            modelID: modelID
        )

        XCTAssertEqual(conversation.providerID, .ollama)
        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.validationModelIDs, [modelID])
        XCTAssertTrue(snapshot.chatMessages.isEmpty)
    }

    func testProviderCreationRequiresNonemptySelectedModel() async {
        let client = OllamaClientSpy()
        let provider = OllamaProvider(client: client)

        for modelID: String? in [nil, ""] {
            do {
                _ = try await provider.makeConversation(
                    context: .init(text: "port: 3000"),
                    modelID: modelID
                )
                XCTFail("Expected a selected model to be required")
            } catch {
                XCTAssertEqual(error as? LocalAIError, .ollamaModelRequired)
            }
        }

        let snapshot = await client.snapshot()
        XCTAssertTrue(snapshot.validationModelIDs.isEmpty)
    }

    func testConversationStartsWithExactProviderNeutralSystemPrompt() async throws {
        let client = OllamaClientSpy()
        let context = SanitizedProcessContext(
            text: "port: 3000\ncommand: tool --token=[REDACTED]"
        )
        let conversation = OllamaConversation(
            client: client,
            modelID: modelID,
            context: context
        )
        let response = Task { try await conversation.respond(to: "Explain it") }

        await client.waitUntilChatCount(1)

        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.chatModelIDs, [modelID])
        XCTAssertEqual(snapshot.chatMessages.count, 1)
        XCTAssertEqual(
            snapshot.chatMessages[0],
            [
                .init(
                    role: "system",
                    content: """
                    You are a concise assistant inside Port Radar, a macOS menu-bar app that lists localhost listeners.
                    The user is asking about one specific process. Use only the process context below.
                    If something isn’t in the context, say you don’t know — don’t invent system state.
                    Prefer short, practical answers for developers.

                    Process context:
                    port: 3000
                    command: tool --token=[REDACTED]
                    """
                ),
                .init(role: "user", content: "Explain it"),
            ]
        )
        XCTAssertFalse(snapshot.chatMessages[0][0].content.contains("raw-secret"))

        await client.completeNextChat(with: .success("Local answer"))
        _ = try await response.value
    }

    func testSuccessfulResponseCommitsUserAndAssistantMessages() async throws {
        let client = OllamaClientSpy()
        let conversation = makeConversation(client: client)

        let first = Task { try await conversation.respond(to: "First question") }
        await client.waitUntilChatCount(1)
        await client.completeNextChat(with: .success("First answer"))
        let firstAnswer = try await first.value
        XCTAssertEqual(firstAnswer, "First answer")

        let second = Task { try await conversation.respond(to: "Second question") }
        await client.waitUntilChatCount(2)
        let snapshot = await client.snapshot()
        XCTAssertEqual(
            snapshot.chatMessages[1].map(\.role),
            ["system", "user", "assistant", "user"]
        )
        XCTAssertEqual(
            snapshot.chatMessages[1].map(\.content).suffix(3),
            ["First question", "First answer", "Second question"]
        )
        await client.completeNextChat(with: .success("Second answer"))
        _ = try await second.value
    }

    func testFailedResponseCommitsNeitherCandidateUserNorAssistant() async throws {
        let client = OllamaClientSpy()
        let conversation = makeConversation(client: client)

        let failed = Task { try await conversation.respond(to: "Failed question") }
        await client.waitUntilChatCount(1)
        await client.completeNextChat(with: .failure(.failed))
        do {
            _ = try await failed.value
            XCTFail("Expected the first response to fail")
        } catch SyntheticClientError.failed {
            // Expected.
        }

        let retry = Task { try await conversation.respond(to: "Retry question") }
        await client.waitUntilChatCount(2)
        let snapshot = await client.snapshot()
        XCTAssertEqual(
            snapshot.chatMessages[1].map(\.role),
            ["system", "user"]
        )
        XCTAssertEqual(snapshot.chatMessages[1].last?.content, "Retry question")
        XCTAssertFalse(
            snapshot.chatMessages[1].contains(where: {
                $0.content.contains("Failed question")
            })
        )
        await client.completeNextChat(with: .success("Recovered"))
        _ = try await retry.value
    }

    func testConcurrentResponsesAreSerializedAndUseCommittedHistory() async throws {
        let client = OllamaClientSpy()
        let conversation = makeConversation(client: client)

        let first = Task { try await conversation.respond(to: "First question") }
        await client.waitUntilChatCount(1)
        let secondStarted = expectation(description: "second task started")
        let second = Task {
            secondStarted.fulfill()
            return try await conversation.respond(to: "Second question")
        }
        await fulfillment(of: [secondStarted], timeout: 1)
        for _ in 0..<20 { await Task.yield() }

        var snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.chatMessages.count, 1)

        await client.completeNextChat(with: .success("First answer"))
        let firstAnswer = try await first.value
        XCTAssertEqual(firstAnswer, "First answer")
        await client.waitUntilChatCount(2)
        snapshot = await client.snapshot()
        XCTAssertEqual(
            snapshot.chatMessages[1].map(\.content).suffix(3),
            ["First question", "First answer", "Second question"]
        )
        await client.completeNextChat(with: .success("Second answer"))
        let secondAnswer = try await second.value
        XCTAssertEqual(secondAnswer, "Second answer")
    }

    func testCloseDuringRequestRejectsLateResponseAndUnloadsExactlyOnce() async {
        let client = OllamaClientSpy()
        let conversation = makeConversation(client: client)
        let response = Task { try await conversation.respond(to: "Question") }
        await client.waitUntilChatCount(1)

        await conversation.close()
        await conversation.close()

        var snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.unloadModelIDs, [modelID])
        await client.completeNextChat(with: .success("Too late"))
        do {
            _ = try await response.value
            XCTFail("Expected the late response to be rejected")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        do {
            _ = try await conversation.respond(to: "After close")
            XCTFail("Expected closed conversation to reject future use")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.chatMessages.count, 1)
        XCTAssertEqual(snapshot.unloadModelIDs, [modelID])
    }

    func testCloseBeforeFirstRequestDoesNotUnload() async {
        let client = OllamaClientSpy()
        let conversation = makeConversation(client: client)

        await conversation.close()
        await conversation.close()

        let snapshot = await client.snapshot()
        XCTAssertTrue(snapshot.chatMessages.isEmpty)
        XCTAssertTrue(snapshot.unloadModelIDs.isEmpty)
    }

    private func makeConversation(
        client: OllamaClientSpy
    ) -> OllamaConversation {
        OllamaConversation(
            client: client,
            modelID: modelID,
            context: .init(text: "port: 3000")
        )
    }
}
