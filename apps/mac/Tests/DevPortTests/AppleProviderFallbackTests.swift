import XCTest
@testable import DevPort

private struct AppleSessionSnapshot: Equatable, Sendable {
    let responsePrompts: [String]
    let activeResponses: Int
    let maximumConcurrentResponses: Int
    let cancellationCount: Int
    let closeCount: Int
}

private actor ControlledAppleSession: AppleModelSession {
    private var responsePrompts: [String] = []
    private var activeResponses = 0
    private var maximumConcurrentResponses = 0
    private var cancellationCount = 0
    private var closeCount = 0
    private var pendingResponses:
        [CheckedContinuation<String, any Error>] = []
    private var responseCountWaiters:
        [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancellationWaiters:
        [(Int, CheckedContinuation<Void, Never>)] = []

    func respond(to prompt: String) async throws -> String {
        responsePrompts.append(prompt)
        activeResponses += 1
        maximumConcurrentResponses = max(
            maximumConcurrentResponses,
            activeResponses
        )
        resumeResponseCountWaiters()
        defer { activeResponses -= 1 }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingResponses.append(continuation)
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
    }

    func close() async {
        closeCount += 1
    }

    func waitUntilResponseCount(_ count: Int) async {
        guard responsePrompts.count < count else { return }
        await withCheckedContinuation { continuation in
            responseCountWaiters.append((count, continuation))
        }
    }

    func waitUntilCancellationCount(_ count: Int) async {
        guard cancellationCount < count else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append((count, continuation))
        }
    }

    func completeNextResponse(_ response: String) {
        pendingResponses.removeFirst().resume(returning: response)
    }

    func snapshot() -> AppleSessionSnapshot {
        .init(
            responsePrompts: responsePrompts,
            activeResponses: activeResponses,
            maximumConcurrentResponses: maximumConcurrentResponses,
            cancellationCount: cancellationCount,
            closeCount: closeCount
        )
    }

    private func recordCancellation() {
        cancellationCount += 1
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in cancellationWaiters {
            if cancellationCount >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        cancellationWaiters = remaining
    }

    private func resumeResponseCountWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in responseCountWaiters {
            if responsePrompts.count >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        responseCountWaiters = remaining
    }
}

private actor CompletionCounter {
    private var value = 0

    func increment() { value += 1 }
    func count() -> Int { value }
}

final class AppleProviderFallbackTests: XCTestCase {
    func testAppleProviderAlwaysIdentifiesAsApple() {
        XCTAssertEqual(AppleFoundationModelProvider().id, .apple)
    }

    func testLiveResolverComposesAppleAndOllamaProvidersWithoutDiscovery() {
        let resolver = AIProviderResolver.live

        XCTAssertEqual(resolver.apple.id, .apple)
        XCTAssertEqual(resolver.ollama.id, .ollama)
    }

    func testConcurrentResponsesAreSerializedInCallOrder() async throws {
        let session = ControlledAppleSession()
        let conversation = AppleFoundationModelConversation(session: session)
        let first = Task {
            try await conversation.respond(to: "First question")
        }
        await session.waitUntilResponseCount(1)

        let secondStarted = expectation(description: "second caller started")
        let second = Task {
            secondStarted.fulfill()
            return try await conversation.respond(to: "Second question")
        }
        await fulfillment(of: [secondStarted], timeout: 1)
        for _ in 0..<20 { await Task.yield() }

        var snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.responsePrompts, ["First question"])
        XCTAssertEqual(snapshot.maximumConcurrentResponses, 1)

        await session.completeNextResponse("First answer")
        let firstAnswer = try await first.value
        XCTAssertEqual(firstAnswer, "First answer")
        await session.waitUntilResponseCount(2)
        snapshot = await session.snapshot()
        XCTAssertEqual(
            snapshot.responsePrompts,
            ["First question", "Second question"]
        )
        XCTAssertEqual(snapshot.maximumConcurrentResponses, 1)

        await session.completeNextResponse("Second answer")
        let secondAnswer = try await second.value
        XCTAssertEqual(secondAnswer, "Second answer")
        await conversation.close()
    }

    func testCloseAwaitsUnwindBeforeReleaseAndRejectsLateResponse() async {
        let session = ControlledAppleSession()
        let conversation = AppleFoundationModelConversation(session: session)
        let response = Task {
            try await conversation.respond(to: "Question")
        }
        await session.waitUntilResponseCount(1)

        let completedCloses = CompletionCounter()
        let firstClose = Task {
            await conversation.close()
            await completedCloses.increment()
        }
        let secondClose = Task {
            await conversation.close()
            await completedCloses.increment()
        }
        await session.waitUntilCancellationCount(1)

        var snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.cancellationCount, 1)
        XCTAssertEqual(snapshot.activeResponses, 1)
        XCTAssertEqual(snapshot.closeCount, 0)
        let completedBeforeUnwind = await completedCloses.count()
        XCTAssertEqual(completedBeforeUnwind, 0)

        await session.completeNextResponse("Too late")
        await firstClose.value
        await secondClose.value

        do {
            _ = try await response.value
            XCTFail("Expected the late response to be rejected")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        await conversation.close()
        snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.activeResponses, 0)
        XCTAssertEqual(snapshot.closeCount, 1)
        let completedAfterUnwind = await completedCloses.count()
        XCTAssertEqual(completedAfterUnwind, 2)
    }

    func testCloseCancelsQueuedResponseWithoutStartingIt() async {
        let session = ControlledAppleSession()
        let conversation = AppleFoundationModelConversation(session: session)
        let active = Task {
            try await conversation.respond(to: "Active")
        }
        await session.waitUntilResponseCount(1)

        let queuedStarted = expectation(description: "queued caller started")
        let queued = Task {
            queuedStarted.fulfill()
            return try await conversation.respond(to: "Queued")
        }
        await fulfillment(of: [queuedStarted], timeout: 1)
        for _ in 0..<20 { await Task.yield() }

        let close = Task { await conversation.close() }
        await session.waitUntilCancellationCount(1)
        await session.completeNextResponse("Late")
        await close.value

        for task in [active, queued] {
            do {
                _ = try await task.value
                XCTFail("Expected close to cancel every response")
            } catch is CancellationError {
                // Expected.
            } catch {
                XCTFail("Expected CancellationError, got \(error)")
            }
        }

        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.responsePrompts, ["Active"])
        XCTAssertEqual(snapshot.maximumConcurrentResponses, 1)
        XCTAssertEqual(snapshot.closeCount, 1)
    }

    #if !canImport(FoundationModels)
    func testAppleProviderIsUnavailableWithoutFramework() async {
        let availability = await AppleFoundationModelProvider().availability(
            modelID: nil
        )

        XCTAssertEqual(
            availability,
            .unavailable(.appleUnavailable(
                "Apple Intelligence requires macOS 26 or later."
            ))
        )
    }

    func testAppleProviderCannotCreateConversationWithoutFramework() async {
        do {
            _ = try await AppleFoundationModelProvider().makeConversation(
                context: SanitizedProcessContext(text: "port: 3000"),
                modelID: nil
            )
            XCTFail("Expected Apple provider to be unavailable")
        } catch {
            XCTAssertEqual(
                error as? LocalAIError,
                .appleUnavailable(
                    "Apple Intelligence requires macOS 26 or later."
                )
            )
        }
    }
    #endif
}
