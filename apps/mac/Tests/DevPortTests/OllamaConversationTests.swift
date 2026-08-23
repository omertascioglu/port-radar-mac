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

private struct ModelChangeClientSnapshot: Equatable, Sendable {
    let validationModelIDs: [String]
    let chatMessages: [[OllamaChatMessage]]
}

private actor ModelChangeClient: OllamaClientProtocol {
    private var validationResults: [ClientValidationResult]
    private var validationModelIDs: [String] = []
    private var chatMessages: [[OllamaChatMessage]] = []

    init(validationResults: [ClientValidationResult]) {
        self.validationResults = validationResults
    }

    func version() async throws -> String { "test" }
    func localModels() async throws -> [OllamaModel] { [] }

    func validateLocalModel(_ id: String) async throws {
        validationModelIDs.append(id)
        guard !validationResults.isEmpty else {
            throw SyntheticClientError.failed
        }
        switch validationResults.removeFirst() {
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
        chatMessages.append(messages)
        return "Local answer"
    }

    func unload(model: String) async {}

    func snapshot() -> ModelChangeClientSnapshot {
        .init(
            validationModelIDs: validationModelIDs,
            chatMessages: chatMessages
        )
    }
}

private struct LifecycleClientSnapshot: Equatable, Sendable {
    let validationCalls: Int
    let chatCalls: Int
    let validationCancellationCount: Int
    let chatCancellationCount: Int
    let unloadModelIDs: [String]
}

private actor ControlledChatLifecycleClient: OllamaClientProtocol {
    private var chatCalls = 0
    private var chatCancellationCount = 0
    private var unloadModelIDs: [String] = []
    private var chatContinuation: CheckedContinuation<String, any Error>?
    private var chatStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var lifecycleWaiters: [CheckedContinuation<Void, Never>] = []

    func version() async throws -> String { "test" }
    func localModels() async throws -> [OllamaModel] { [] }
    func validateLocalModel(_ id: String) async throws {}

    func chat(
        model: String,
        messages: [OllamaChatMessage]
    ) async throws -> String {
        chatCalls += 1
        let waiters = chatStartWaiters
        chatStartWaiters.removeAll()
        waiters.forEach { $0.resume() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                chatContinuation = continuation
            }
        } onCancel: {
            Task { await self.recordChatCancellation() }
        }
    }

    func unload(model: String) async {
        unloadModelIDs.append(model)
        signalLifecycleEvent()
    }

    func waitUntilChatStarts() async {
        guard chatCalls == 0 else { return }
        await withCheckedContinuation { continuation in
            chatStartWaiters.append(continuation)
        }
    }

    func waitUntilCancellationOrUnload() async {
        guard chatCancellationCount == 0, unloadModelIDs.isEmpty else { return }
        await withCheckedContinuation { continuation in
            lifecycleWaiters.append(continuation)
        }
    }

    func completeChat(with result: Result<String, SyntheticClientError>) {
        chatContinuation?.resume(with: result)
        chatContinuation = nil
    }

    func snapshot() -> LifecycleClientSnapshot {
        .init(
            validationCalls: 0,
            chatCalls: chatCalls,
            validationCancellationCount: 0,
            chatCancellationCount: chatCancellationCount,
            unloadModelIDs: unloadModelIDs
        )
    }

    private func recordChatCancellation() {
        chatCancellationCount += 1
        signalLifecycleEvent()
    }

    private func signalLifecycleEvent() {
        let waiters = lifecycleWaiters
        lifecycleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor ControlledValidationLifecycleClient: OllamaClientProtocol {
    private var validationCalls = 0
    private var chatCalls = 0
    private var validationCancellationCount = 0
    private var unloadModelIDs: [String] = []
    private var validationContinuation: CheckedContinuation<Void, any Error>?
    private var requestStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var lifecycleWaiters: [CheckedContinuation<Void, Never>] = []

    func version() async throws -> String { "test" }
    func localModels() async throws -> [OllamaModel] { [] }

    func validateLocalModel(_ id: String) async throws {
        validationCalls += 1
        signalRequestStarted()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                validationContinuation = continuation
            }
        } onCancel: {
            Task { await self.recordValidationCancellation() }
        }
    }

    func chat(
        model: String,
        messages: [OllamaChatMessage]
    ) async throws -> String {
        chatCalls += 1
        signalRequestStarted()
        return "Privacy boundary bypassed"
    }

    func unload(model: String) async {
        unloadModelIDs.append(model)
        signalLifecycleEvent()
    }

    func waitUntilAnyRequestStarts() async {
        guard validationCalls == 0, chatCalls == 0 else { return }
        await withCheckedContinuation { continuation in
            requestStartWaiters.append(continuation)
        }
    }

    func waitUntilCancellationOrUnload() async {
        guard validationCancellationCount == 0, unloadModelIDs.isEmpty else {
            return
        }
        await withCheckedContinuation { continuation in
            lifecycleWaiters.append(continuation)
        }
    }

    func completeValidation(
        with result: Result<Void, SyntheticClientError>
    ) {
        validationContinuation?.resume(with: result)
        validationContinuation = nil
    }

    func snapshot() -> LifecycleClientSnapshot {
        .init(
            validationCalls: validationCalls,
            chatCalls: chatCalls,
            validationCancellationCount: validationCancellationCount,
            chatCancellationCount: 0,
            unloadModelIDs: unloadModelIDs
        )
    }

    private func recordValidationCancellation() {
        validationCancellationCount += 1
        signalLifecycleEvent()
    }

    private func signalRequestStarted() {
        let waiters = requestStartWaiters
        requestStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func signalLifecycleEvent() {
        let waiters = lifecycleWaiters
        lifecycleWaiters.removeAll()
        waiters.forEach { $0.resume() }
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

    func testEveryResponseRevalidatesAndDoesNotChatAfterModelBecomesRemote() async throws {
        let client = ModelChangeClient(validationResults: [
            .success,
            .localError(.remoteModelRejected),
        ])
        let conversation = OllamaConversation(
            client: client,
            modelID: modelID,
            context: .init(text: "sanitized-only-context")
        )

        let firstAnswer = try await conversation.respond(to: "First question")
        XCTAssertEqual(firstAnswer, "Local answer")

        do {
            _ = try await conversation.respond(to: "Blocked question")
            XCTFail("Expected the model change to block chat")
        } catch {
            XCTAssertEqual(error as? LocalAIError, .remoteModelRejected)
        }

        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.validationModelIDs, [modelID, modelID])
        XCTAssertEqual(snapshot.chatMessages.count, 1)
        XCTAssertTrue(
            snapshot.chatMessages[0].contains(where: {
                $0.content.contains("sanitized-only-context")
            })
        )
        XCTAssertFalse(
            snapshot.chatMessages.flatMap { $0 }.contains(where: {
                $0.content.contains("Blocked question")
            })
        )
    }

    func testCloseAwaitsCancelledChatBeforeUnloadingExactlyOnce() async {
        let client = ControlledChatLifecycleClient()
        let conversation = OllamaConversation(
            client: client,
            modelID: modelID,
            context: .init(text: "port: 3000")
        )
        let response = Task { try await conversation.respond(to: "Question") }
        await client.waitUntilChatStarts()

        let firstClose = Task { await conversation.close() }
        let secondClose = Task { await conversation.close() }
        await client.waitUntilCancellationOrUnload()

        var snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.chatCancellationCount, 1)
        XCTAssertTrue(snapshot.unloadModelIDs.isEmpty)

        await client.completeChat(with: .failure(.failed))
        await firstClose.value
        await secondClose.value

        do {
            _ = try await response.value
            XCTFail("Expected close to cancel the active response")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.chatCalls, 1)
        XCTAssertEqual(snapshot.unloadModelIDs, [modelID])
    }

    func testCloseAwaitsCancelledValidationWithoutChatOrUnload() async {
        let client = ControlledValidationLifecycleClient()
        let conversation = OllamaConversation(
            client: client,
            modelID: modelID,
            context: .init(text: "port: 3000")
        )
        let response = Task { try await conversation.respond(to: "Question") }
        await client.waitUntilAnyRequestStarts()

        let close = Task { await conversation.close() }
        await client.waitUntilCancellationOrUnload()

        var snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.validationCalls, 1)
        XCTAssertEqual(snapshot.validationCancellationCount, 1)
        XCTAssertEqual(snapshot.chatCalls, 0)
        XCTAssertTrue(snapshot.unloadModelIDs.isEmpty)

        await client.completeValidation(with: .failure(.failed))
        await close.value

        do {
            _ = try await response.value
            XCTFail("Expected close to cancel in-flight validation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.chatCalls, 0)
        XCTAssertTrue(snapshot.unloadModelIDs.isEmpty)
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
        let client = ControlledChatLifecycleClient()
        let conversation = OllamaConversation(
            client: client,
            modelID: modelID,
            context: .init(text: "port: 3000")
        )
        let response = Task { try await conversation.respond(to: "Question") }
        await client.waitUntilChatStarts()

        let close = Task { await conversation.close() }
        await client.waitUntilCancellationOrUnload()
        await client.completeChat(with: .success("Too late"))
        await close.value
        await conversation.close()

        var snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.unloadModelIDs, [modelID])
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
        XCTAssertEqual(snapshot.chatCalls, 1)
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
