import XCTest
@testable import DevPort

private actor RegistryConversationSpy: LocalAIConversation {
    nonisolated let providerID: LocalAIProviderID = .ollama

    private let chunks: [String]
    private var prompts: [String] = []
    private var closeCount = 0

    init(chunks: [String] = []) {
        self.chunks = chunks
    }

    func streamResponse(to prompt: String) async throws -> LocalAITextStream {
        prompts.append(prompt)
        let emitted = chunks.isEmpty ? [prompt] : chunks
        return LocalAITextStream { continuation in
            emitted.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    func close() async {
        closeCount += 1
    }

    func recordedPrompts() -> [String] { prompts }

    func recordedCloseCount() -> Int { closeCount }
}

private actor BlockingRegistryConversationSpy: LocalAIConversation {
    nonisolated let providerID: LocalAIProviderID = .ollama

    private var closeCount = 0
    private var didStartClosing = false
    private var closeStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var canFinishClosing = false
    private var closeFinishWaiters: [CheckedContinuation<Void, Never>] = []

    func streamResponse(to prompt: String) async throws -> LocalAITextStream {
        LocalAITextStream { continuation in
            continuation.yield(prompt)
            continuation.finish()
        }
    }

    func close() async {
        closeCount += 1
        didStartClosing = true
        let startWaiters = closeStartWaiters
        closeStartWaiters.removeAll()
        startWaiters.forEach { $0.resume() }

        guard !canFinishClosing else { return }
        await withCheckedContinuation { continuation in
            closeFinishWaiters.append(continuation)
        }
    }

    func waitUntilCloseStarts() async {
        guard !didStartClosing else { return }
        await withCheckedContinuation { continuation in
            closeStartWaiters.append(continuation)
        }
    }

    func releaseClose() {
        canFinishClosing = true
        let waiters = closeFinishWaiters
        closeFinishWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func recordedCloseCount() -> Int { closeCount }
}

private final class RegistrationObservedConversation: @unchecked Sendable,
    LocalAIConversation
{
    private let onProviderIDRead: () -> Void
    private let conversation = RegistryConversationSpy()

    init(onProviderIDRead: @escaping () -> Void) {
        self.onProviderIDRead = onProviderIDRead
    }

    var providerID: LocalAIProviderID {
        onProviderIDRead()
        return .ollama
    }

    func streamResponse(to prompt: String) async throws -> LocalAITextStream {
        try await conversation.streamResponse(to: prompt)
    }

    func close() async { await conversation.close() }

    func recordedCloseCount() async -> Int {
        await conversation.recordedCloseCount()
    }
}

private actor RegistryProviderStub: LocalAIProvider {
    nonisolated let id: LocalAIProviderID = .ollama

    private let conversation: any LocalAIConversation

    init(conversation: any LocalAIConversation) {
        self.conversation = conversation
    }

    func availability(modelID: String?) async -> LocalAIAvailability {
        .available
    }

    func makeConversation(
        context: SanitizedProcessContext,
        modelID: String?
    ) async throws -> any LocalAIConversation {
        conversation
    }
}

private actor RegistryUnavailableProvider: LocalAIProvider {
    nonisolated let id: LocalAIProviderID = .apple

    func availability(modelID: String?) async -> LocalAIAvailability {
        .unavailable(.appleUnavailable("Unavailable in registry test"))
    }

    func makeConversation(
        context: SanitizedProcessContext,
        modelID: String?
    ) async throws -> any LocalAIConversation {
        throw LocalAIError.appleUnavailable("Unavailable in registry test")
    }
}

private actor TerminationCleanupProbe {
    private var didStart = false
    private var didFinish = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func run() async {
        didStart = true
        let pendingStarts = startWaiters
        startWaiters.removeAll()
        pendingStarts.forEach { $0.resume() }

        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        didFinish = true
        let pendingFinishes = finishWaiters
        finishWaiters.removeAll()
        pendingFinishes.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let pending = releaseWaiters
        releaseWaiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitUntilFinished() async {
        guard !didFinish else { return }
        await withCheckedContinuation { continuation in
            finishWaiters.append(continuation)
        }
    }

    func finished() -> Bool { didFinish }
}

final class LocalAIConversationRegistryTests: XCTestCase {
    func testManagedConversationForwardsStreamedChunksInOrder() async throws {
        let registry = LocalAIConversationRegistry()
        let conversation = RegistryConversationSpy(
            chunks: ["Hel", "lo", " there"]
        )
        let registered = await registry.register(
            token: UUID(),
            conversation: conversation
        )
        let managed = try XCTUnwrap(registered)

        var received: [String] = []
        for try await chunk in try await managed.streamResponse(to: "Question") {
            received.append(chunk)
        }

        XCTAssertEqual(received, ["Hel", "lo", " there"])
        XCTAssertEqual(managed.providerID, .ollama)
        let prompts = await conversation.recordedPrompts()
        XCTAssertEqual(prompts, ["Question"])

        await registry.closeActive()

        let closeCount = await conversation.recordedCloseCount()
        XCTAssertEqual(closeCount, 1)
    }

    func testManagedConversationRejectsStreamingAfterClose() async throws {
        let registry = LocalAIConversationRegistry()
        let conversation = RegistryConversationSpy()
        let registered = await registry.register(
            token: UUID(),
            conversation: conversation
        )
        let managed = try XCTUnwrap(registered)

        await registry.closeActive()

        do {
            _ = try await managed.streamResponse(to: "After close")
            XCTFail("Expected the closed wrapper to reject new streams")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let prompts = await conversation.recordedPrompts()
        let closeCount = await conversation.recordedCloseCount()
        XCTAssertTrue(prompts.isEmpty)
        XCTAssertEqual(closeCount, 1)
    }

    func testRegisterThenCloseActiveClosesConversationExactlyOnce() async {
        let registry = LocalAIConversationRegistry()
        let conversation = RegistryConversationSpy()

        _ = await registry.register(
            token: UUID(),
            conversation: conversation
        )
        await registry.closeActive()
        await registry.closeActive()

        let closeCount = await conversation.recordedCloseCount()
        XCTAssertEqual(closeCount, 1)
    }

    func testRegisteringSecondConversationClosesFirstBeforeReturning() async {
        let registry = LocalAIConversationRegistry()
        let first = RegistryConversationSpy()
        let second = RegistryConversationSpy()

        _ = await registry.register(token: UUID(), conversation: first)
        _ = await registry.register(token: UUID(), conversation: second)

        let firstCloseCount = await first.recordedCloseCount()
        let secondCloseCount = await second.recordedCloseCount()
        XCTAssertEqual(firstCloseCount, 1)
        XCTAssertEqual(secondCloseCount, 0)
    }

    func testUnregisterOnlyRemovesMatchingToken() async {
        let registry = LocalAIConversationRegistry()
        let conversation = RegistryConversationSpy()
        let token = UUID()

        _ = await registry.register(token: token, conversation: conversation)
        await registry.unregister(token: UUID())
        await registry.closeActive()

        let closeCount = await conversation.recordedCloseCount()
        XCTAssertEqual(closeCount, 1)
    }

    func testMatchingUnregisterMakesCloseActiveHarmless() async {
        let registry = LocalAIConversationRegistry()
        let conversation = RegistryConversationSpy()
        let token = UUID()

        _ = await registry.register(token: token, conversation: conversation)
        await registry.unregister(token: token)
        await registry.closeActive()

        let closeCount = await conversation.recordedCloseCount()
        XCTAssertEqual(closeCount, 0)
    }

    func testCloseActiveWithNoConversationIsHarmless() async {
        let registry = LocalAIConversationRegistry()

        await registry.closeActive()
        await registry.closeActive()
    }

    func testConcurrentRegistersCloseEverySupersededConversation() async {
        let registry = LocalAIConversationRegistry()
        let initial = BlockingRegistryConversationSpy()
        let firstReplacement = RegistryConversationSpy()
        let secondEnteredRegister = expectation(
            description: "second register entered the registry"
        )
        let finalReplacement = RegistrationObservedConversation {
            secondEnteredRegister.fulfill()
        }

        _ = await registry.register(token: UUID(), conversation: initial)
        let firstRegistration = Task {
            _ = await registry.register(
                token: UUID(),
                conversation: firstReplacement
            )
        }
        await initial.waitUntilCloseStarts()

        let secondRegistration = Task {
            _ = await registry.register(
                token: UUID(),
                conversation: finalReplacement
            )
        }
        await fulfillment(of: [secondEnteredRegister], timeout: 1)
        await initial.releaseClose()
        await firstRegistration.value
        await secondRegistration.value
        await registry.closeActive()

        let initialCloseCount = await initial.recordedCloseCount()
        let firstReplacementCloseCount =
            await firstReplacement.recordedCloseCount()
        let finalReplacementCloseCount =
            await finalReplacement.recordedCloseCount()
        XCTAssertEqual(initialCloseCount, 1)
        XCTAssertEqual(firstReplacementCloseCount, 1)
        XCTAssertEqual(finalReplacementCloseCount, 1)
    }

    func testCloseActiveRejectsRegistrationRacingTermination() async {
        let registry = LocalAIConversationRegistry()
        let active = BlockingRegistryConversationSpy()
        let registrationEntered = expectation(
            description: "late register entered the registry"
        )
        let lateConversation = RegistrationObservedConversation {
            registrationEntered.fulfill()
        }

        _ = await registry.register(token: UUID(), conversation: active)
        let cleanup = Task { await registry.closeActive() }
        await active.waitUntilCloseStarts()

        let lateRegistration = Task {
            return await registry.register(
                token: UUID(),
                conversation: lateConversation
            )
        }
        await fulfillment(of: [registrationEntered], timeout: 1)
        await active.releaseClose()
        await cleanup.value
        let acceptedConversation = await lateRegistration.value

        let activeCloseCount = await active.recordedCloseCount()
        let lateCloseCount = await lateConversation.recordedCloseCount()
        XCTAssertEqual(activeCloseCount, 1)
        XCTAssertEqual(lateCloseCount, 1)
        XCTAssertNil(acceptedConversation)
    }

    func testLateUnregisterCannotRemoveNewestConversation() async {
        let registry = LocalAIConversationRegistry()
        let oldToken = UUID()
        let currentToken = UUID()
        let oldConversation = RegistryConversationSpy()
        let currentConversation = RegistryConversationSpy()

        _ = await registry.register(
            token: oldToken,
            conversation: oldConversation
        )
        _ = await registry.register(
            token: currentToken,
            conversation: currentConversation
        )
        await registry.unregister(token: oldToken)
        await registry.closeActive()

        let oldCloseCount = await oldConversation.recordedCloseCount()
        let currentCloseCount = await currentConversation.recordedCloseCount()
        XCTAssertEqual(oldCloseCount, 1)
        XCTAssertEqual(currentCloseCount, 1)
    }

    @MainActor
    func testAgentChatCloseUnregistersAfterProviderCleanup() async {
        let registry = LocalAIConversationRegistry()
        let conversation = RegistryConversationSpy()
        let model = makeChatModel(
            conversation: conversation,
            registry: registry
        )

        await model.bootstrap()
        await model.close()
        await registry.closeActive()

        let closeCount = await conversation.recordedCloseCount()
        XCTAssertEqual(closeCount, 1)
    }

    @MainActor
    func testTerminationRacingModalCloseClosesUnderlyingConversationOnce() async {
        let registry = LocalAIConversationRegistry()
        let conversation = RegistryConversationSpy()
        let model = makeChatModel(
            conversation: conversation,
            registry: registry
        )
        await model.bootstrap()

        async let modalClose: Void = model.close()
        async let terminationClose: Void = registry.closeActive()
        _ = await (modalClose, terminationClose)

        let closeCount = await conversation.recordedCloseCount()
        XCTAssertEqual(closeCount, 1)
    }

    @MainActor
    func testLateOldModalCloseCannotUnregisterNewerChat() async {
        let registry = LocalAIConversationRegistry()
        let oldConversation = RegistryConversationSpy()
        let currentConversation = RegistryConversationSpy()
        let oldModel = makeChatModel(
            conversation: oldConversation,
            registry: registry
        )
        let currentModel = makeChatModel(
            conversation: currentConversation,
            registry: registry
        )

        await oldModel.bootstrap()
        await currentModel.bootstrap()
        await oldModel.close()
        await registry.closeActive()

        let oldCloseCount = await oldConversation.recordedCloseCount()
        let currentCloseCount = await currentConversation.recordedCloseCount()
        XCTAssertEqual(oldCloseCount, 1)
        XCTAssertEqual(currentCloseCount, 1)
    }

    @MainActor
    func testBootstrapCloseAndTerminationRaceLeavesNoConversationOwned() async {
        let registry = LocalAIConversationRegistry()
        let previous = BlockingRegistryConversationSpy()
        let resolved = RegistryConversationSpy()
        _ = await registry.register(token: UUID(), conversation: previous)
        let model = makeChatModel(
            conversation: resolved,
            registry: registry
        )

        let bootstrap = Task { await model.bootstrap() }
        await previous.waitUntilCloseStarts()
        model.beginClose()
        let terminationCleanup = Task { await registry.closeActive() }
        await previous.releaseClose()

        await bootstrap.value
        await model.close()
        await terminationCleanup.value

        let previousCloseCount = await previous.recordedCloseCount()
        let resolvedCloseCount = await resolved.recordedCloseCount()
        XCTAssertEqual(previousCloseCount, 1)
        XCTAssertEqual(resolvedCloseCount, 1)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertNil(model.badgeText)
        XCTAssertNil(model.availabilityNote)
    }

    @MainActor
    func testTerminatedRegistryRejectsBootstrapConversation() async {
        let registry = LocalAIConversationRegistry()
        let conversation = RegistryConversationSpy()
        await registry.closeActive()
        let model = makeChatModel(
            conversation: conversation,
            registry: registry
        )

        await model.bootstrap()
        await model.close()

        let closeCount = await conversation.recordedCloseCount()
        XCTAssertEqual(closeCount, 1)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertNil(model.badgeText)
        XCTAssertNil(model.availabilityNote)
    }

    @MainActor
    func testApplicationTerminationStartsCleanupWithoutBlocking() async {
        let probe = TerminationCleanupProbe()
        let delegate = AppDelegate(cleanup: { await probe.run() })

        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )
        await probe.waitUntilStarted()

        let finishedBeforeRelease = await probe.finished()
        XCTAssertFalse(finishedBeforeRelease)
        await probe.release()
        await probe.waitUntilFinished()
    }

    @MainActor
    private func makeChatModel(
        conversation: any LocalAIConversation,
        registry: LocalAIConversationRegistry
    ) -> AgentChatModel {
        let processID = Int32(ProcessInfo.processInfo.processIdentifier)
        let server = DevServer(
            listener: ListeningPort(port: 3000, pid: processID),
            details: ProcessDetails(
                pid: processID,
                parentPID: processID,
                executablePath: "/usr/local/bin/node",
                arguments: ["node", "app.js", "--port", "3000"],
                workingDirectory: "/tmp/RegistryTestProject",
                startTime: nil
            ),
            project: ProjectInfo(
                name: "RegistryTestProject",
                rootPath: "/tmp/RegistryTestProject",
                framework: .node
            )
        )
        return AgentChatModel(
            server: server,
            resolver: AIProviderResolver(
                apple: RegistryUnavailableProvider(),
                ollama: RegistryProviderStub(conversation: conversation)
            ),
            preference: .ollama,
            ollamaModelID: "qwen3:4b",
            conversationRegistry: registry
        )
    }
}
