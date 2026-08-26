import XCTest
@testable import DevPort

private enum AgentChatSyntheticError: Error, LocalizedError, Sendable {
    case secretBearing

    var errorDescription: String? {
        "synthetic-secret-must-not-reach-the-chat"
    }
}

private struct ChatProviderSnapshot: Sendable {
    let availabilityModelIDs: [String?]
    let creationModelIDs: [String?]
    let contexts: [SanitizedProcessContext]
}

private actor ChatProviderSpy: LocalAIProvider {
    nonisolated let id: LocalAIProviderID

    private let conversation: any LocalAIConversation
    private let creationError: (any Error & Sendable)?
    private var availabilityModelIDs: [String?] = []
    private var creationModelIDs: [String?] = []
    private var contexts: [SanitizedProcessContext] = []

    init(
        id: LocalAIProviderID,
        conversation: any LocalAIConversation,
        creationError: (any Error & Sendable)? = nil
    ) {
        self.id = id
        self.conversation = conversation
        self.creationError = creationError
    }

    func availability(modelID: String?) async -> LocalAIAvailability {
        availabilityModelIDs.append(modelID)
        return .available
    }

    func makeConversation(
        context: SanitizedProcessContext,
        modelID: String?
    ) async throws -> any LocalAIConversation {
        creationModelIDs.append(modelID)
        contexts.append(context)
        if let creationError { throw creationError }
        return conversation
    }

    func snapshot() -> ChatProviderSnapshot {
        .init(
            availabilityModelIDs: availabilityModelIDs,
            creationModelIDs: creationModelIDs,
            contexts: contexts
        )
    }
}

private actor NeverAvailableProvider: LocalAIProvider {
    nonisolated let id: LocalAIProviderID

    init(id: LocalAIProviderID) {
        self.id = id
    }

    func availability(modelID: String?) async -> LocalAIAvailability {
        .unavailable(.appleUnavailable("unavailable"))
    }

    func makeConversation(
        context: SanitizedProcessContext,
        modelID: String?
    ) async throws -> any LocalAIConversation {
        throw LocalAIError.appleUnavailable("unavailable")
    }
}

/// One finished reply delivered as a single streamed chunk, so these fakes keep
/// asserting on complete replies while the contract is a stream.
private func oneChunkStream(_ text: String) -> LocalAITextStream {
    LocalAITextStream { continuation in
        continuation.yield(text)
        continuation.finish()
    }
}

private struct ConversationSnapshot: Sendable {
    let prompts: [String]
    let closeCount: Int
}

private actor ImmediateConversationSpy: LocalAIConversation {
    nonisolated let providerID: LocalAIProviderID

    private let response: String
    private let responseError: (any Error & Sendable)?
    private var prompts: [String] = []
    private var closeCount = 0

    init(
        providerID: LocalAIProviderID,
        response: String = "A local answer",
        responseError: (any Error & Sendable)? = nil
    ) {
        self.providerID = providerID
        self.response = response
        self.responseError = responseError
    }

    func streamResponse(to prompt: String) async throws -> LocalAITextStream {
        prompts.append(prompt)
        if let responseError { throw responseError }
        return oneChunkStream(response)
    }

    func close() async {
        closeCount += 1
    }

    func snapshot() -> ConversationSnapshot {
        .init(prompts: prompts, closeCount: closeCount)
    }
}

private actor ControlledConversationSpy: LocalAIConversation {
    nonisolated let providerID: LocalAIProviderID

    private var prompts: [String] = []
    private var closeCount = 0
    private var pendingResponse: CheckedContinuation<String, any Error>?
    private var responseWaiters: [CheckedContinuation<Void, Never>] = []

    init(providerID: LocalAIProviderID) {
        self.providerID = providerID
    }

    func streamResponse(to prompt: String) async throws -> LocalAITextStream {
        prompts.append(prompt)
        let waiters = responseWaiters
        responseWaiters.removeAll()
        waiters.forEach { $0.resume() }
        let reply = try await withCheckedThrowingContinuation { continuation in
            pendingResponse = continuation
        }
        return oneChunkStream(reply)
    }

    func close() async {
        closeCount += 1
    }

    func waitUntilResponding() async {
        guard prompts.isEmpty else { return }
        await withCheckedContinuation { continuation in
            responseWaiters.append(continuation)
        }
    }

    func complete(with result: Result<String, AgentChatSyntheticError>) {
        pendingResponse?.resume(with: result)
        pendingResponse = nil
    }

    func snapshot() -> ConversationSnapshot {
        .init(prompts: prompts, closeCount: closeCount)
    }
}

private actor CancellationAwareConversationSpy: LocalAIConversation {
    nonisolated let providerID: LocalAIProviderID

    private var prompts: [String] = []
    private var closeCount = 0
    private var responseWaiters: [CheckedContinuation<Void, Never>] = []

    init(providerID: LocalAIProviderID) {
        self.providerID = providerID
    }

    func streamResponse(to prompt: String) async throws -> LocalAITextStream {
        prompts.append(prompt)
        let waiters = responseWaiters
        responseWaiters.removeAll()
        waiters.forEach { $0.resume() }
        try await Task.sleep(for: .seconds(30))
        return oneChunkStream("Too late")
    }

    func close() async {
        closeCount += 1
    }

    func waitUntilResponding() async {
        guard prompts.isEmpty else { return }
        await withCheckedContinuation { continuation in
            responseWaiters.append(continuation)
        }
    }

    func snapshot() -> ConversationSnapshot {
        .init(prompts: prompts, closeCount: closeCount)
    }
}

/// Simulates a provider whose response ignores caller cancellation and can
/// unwind only after the provider-level close hook runs.
private actor CloseReleasedConversationSpy: LocalAIConversation {
    nonisolated let providerID: LocalAIProviderID = .ollama

    private var prompts: [String] = []
    private var closeCount = 0
    private var pendingResponse: CheckedContinuation<String, Never>?
    private var responseWaiters: [CheckedContinuation<Void, Never>] = []

    func streamResponse(to prompt: String) async throws -> LocalAITextStream {
        prompts.append(prompt)
        let waiters = responseWaiters
        responseWaiters.removeAll()
        waiters.forEach { $0.resume() }
        let reply = await withCheckedContinuation { continuation in
            pendingResponse = continuation
        }
        return oneChunkStream(reply)
    }

    func close() async {
        closeCount += 1
        pendingResponse?.resume(returning: "Released by close")
        pendingResponse = nil
    }

    func waitUntilResponding() async {
        guard prompts.isEmpty else { return }
        await withCheckedContinuation { continuation in
            responseWaiters.append(continuation)
        }
    }

    func snapshot() -> ConversationSnapshot {
        .init(prompts: prompts, closeCount: closeCount)
    }
}

private actor ControlledCreationProvider: LocalAIProvider {
    nonisolated let id: LocalAIProviderID

    private var availabilityModelIDs: [String?] = []
    private var creationModelIDs: [String?] = []
    private var contexts: [SanitizedProcessContext] = []
    private var creationContinuation:
        CheckedContinuation<any LocalAIConversation, Never>?
    private var creationWaiters: [CheckedContinuation<Void, Never>] = []

    init(id: LocalAIProviderID) {
        self.id = id
    }

    func availability(modelID: String?) async -> LocalAIAvailability {
        availabilityModelIDs.append(modelID)
        return .available
    }

    func makeConversation(
        context: SanitizedProcessContext,
        modelID: String?
    ) async throws -> any LocalAIConversation {
        creationModelIDs.append(modelID)
        contexts.append(context)
        let waiters = creationWaiters
        creationWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            creationContinuation = continuation
        }
    }

    func waitUntilCreationStarts() async {
        guard creationModelIDs.isEmpty else { return }
        await withCheckedContinuation { continuation in
            creationWaiters.append(continuation)
        }
    }

    func completeCreation(with conversation: any LocalAIConversation) {
        creationContinuation?.resume(returning: conversation)
        creationContinuation = nil
    }

    func snapshot() -> ChatProviderSnapshot {
        .init(
            availabilityModelIDs: availabilityModelIDs,
            creationModelIDs: creationModelIDs,
            contexts: contexts
        )
    }
}

@MainActor
private final class ContextInvocationCounter {
    private(set) var count = 0

    func sanitize(_ server: DevServer) -> SanitizedProcessContext {
        count += 1
        return server.sanitizedAgentContext
    }
}

@MainActor
final class AgentChatModelTests: XCTestCase {
    func testBootstrapSanitizesOnceAndUsesPreferenceAndModelSnapshot() async {
        let secret = "synthetic-agent-chat-secret"
        let server = makeServer(arguments: [
            "node", "app.js", "--token", secret, "--port", "3000",
        ])
        let conversation = ImmediateConversationSpy(providerID: .ollama)
        let provider = ControlledCreationProvider(id: .ollama)
        let resolver = AIProviderResolver(
            apple: NeverAvailableProvider(id: .apple),
            ollama: provider
        )
        let counter = ContextInvocationCounter()
        let model = AgentChatModel(
            server: server,
            resolver: resolver,
            preference: .ollama,
            ollamaModelID: "qwen3:4b",
            contextBuilder: { server in counter.sanitize(server) }
        )

        let first = Task { await model.bootstrap() }
        await provider.waitUntilCreationStarts()
        let second = Task { await model.bootstrap() }
        await Task.yield()

        var snapshot = await provider.snapshot()
        XCTAssertEqual(counter.count, 1)
        // Ollama is created directly: probing its availability first would
        // start and stop the private service before the real acquire.
        XCTAssertTrue(snapshot.availabilityModelIDs.isEmpty)
        XCTAssertEqual(snapshot.creationModelIDs.count, 1)
        XCTAssertEqual(snapshot.creationModelIDs.first!, "qwen3:4b")
        XCTAssertEqual(snapshot.contexts.count, 1)
        XCTAssertFalse(snapshot.contexts[0].text.contains(secret))
        XCTAssertTrue(snapshot.contexts[0].text.contains("[REDACTED]"))

        await provider.completeCreation(with: conversation)
        await first.value
        await second.value
        snapshot = await provider.snapshot()
        XCTAssertEqual(snapshot.creationModelIDs.count, 1)
    }

    func testEmptySavedModelResolvesAsNil() async {
        let conversation = ImmediateConversationSpy(providerID: .ollama)
        let provider = ChatProviderSpy(
            id: .ollama,
            conversation: conversation
        )
        let model = makeModel(
            provider: provider,
            preference: .ollama,
            ollamaModelID: ""
        )

        await model.bootstrap()

        let snapshot = await provider.snapshot()
        XCTAssertTrue(snapshot.availabilityModelIDs.isEmpty)
        XCTAssertEqual(snapshot.creationModelIDs.count, 1)
        XCTAssertNil(snapshot.creationModelIDs[0])
    }

    func testBootstrapUsesProviderSpecificBadgeAndDisclosure() async {
        for providerID in [LocalAIProviderID.apple, .ollama] {
            let conversation = ImmediateConversationSpy(providerID: providerID)
            let provider = ChatProviderSpy(
                id: providerID,
                conversation: conversation
            )
            let model = makeModel(
                provider: provider,
                preference: providerID == .apple ? .apple : .ollama
            )

            await model.bootstrap()

            XCTAssertEqual(model.badgeText, providerID.badgeText)
            XCTAssertEqual(model.messages.count, 1)
            XCTAssertEqual(model.messages[0].role, .system)
            XCTAssertEqual(
                model.messages[0].text,
                providerID == .apple
                    ? "Apple's on-device model has sanitized process context."
                    : "Your local Ollama model has sanitized process context."
            )
        }
    }

    func testSendTrimsInputCommitsMessagesAndPreventsConcurrentSend() async {
        let conversation = ControlledConversationSpy(providerID: .ollama)
        let provider = ChatProviderSpy(
            id: .ollama,
            conversation: conversation
        )
        let model = makeModel(provider: provider, preference: .ollama)
        await model.bootstrap()
        model.draft = "  What is this? \n"

        model.send()
        await conversation.waitUntilResponding()
        model.draft = "Second question"
        model.send()

        var snapshot = await conversation.snapshot()
        XCTAssertEqual(snapshot.prompts, ["What is this?"])
        XCTAssertTrue(model.isSending)
        XCTAssertEqual(
            model.messages.filter { $0.role == .user }.map(\.text),
            ["What is this?"]
        )
        await conversation.complete(with: .success("A safe answer"))
        await waitUntil { !model.isSending }

        snapshot = await conversation.snapshot()
        XCTAssertEqual(snapshot.prompts, ["What is this?"])
        XCTAssertEqual(model.draft, "Second question")
        XCTAssertEqual(
            model.messages.filter { $0.role == .assistant }.map(\.text),
            ["A safe answer"]
        )
    }

    func testSendIgnoresWhitespaceOnlyInput() async {
        let conversation = ImmediateConversationSpy(providerID: .ollama)
        let provider = ChatProviderSpy(
            id: .ollama,
            conversation: conversation
        )
        let model = makeModel(provider: provider, preference: .ollama)
        await model.bootstrap()
        model.draft = " \n\t "

        model.send()
        await Task.yield()

        let snapshot = await conversation.snapshot()
        XCTAssertTrue(snapshot.prompts.isEmpty)
        XCTAssertFalse(model.isSending)
        XCTAssertTrue(model.messages.allSatisfy { $0.role != .user })
    }

    func testCancellationAddsNoErrorBubble() async {
        let conversation = CancellationAwareConversationSpy(
            providerID: .ollama
        )
        let provider = ChatProviderSpy(
            id: .ollama,
            conversation: conversation
        )
        let model = makeModel(provider: provider, preference: .ollama)
        await model.bootstrap()
        model.draft = "Cancel this"
        model.send()
        await conversation.waitUntilResponding()

        await model.close()

        let snapshot = await conversation.snapshot()
        XCTAssertEqual(snapshot.closeCount, 1)
        XCTAssertFalse(model.isSending)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertNil(model.availabilityNote)
    }

    func testConversationCancellationAddsNoErrorBubbleWithoutClosing() async {
        let conversation = ImmediateConversationSpy(
            providerID: .ollama,
            responseError: CancellationError()
        )
        let provider = ChatProviderSpy(
            id: .ollama,
            conversation: conversation
        )
        let model = makeModel(provider: provider, preference: .ollama)
        await model.bootstrap()
        model.draft = "Cancel this"

        model.send()
        await waitUntil { !model.isSending }

        XCTAssertEqual(model.messages.count, 2)
        XCTAssertEqual(model.messages[0].role, .system)
        XCTAssertEqual(model.messages[1].role, .user)
        XCTAssertFalse(model.messages.contains {
            $0.text.localizedCaseInsensitiveContains("cancel")
                && $0.role == .system
        })
        XCTAssertNil(model.availabilityNote)
    }

    func testCloseIsConcurrentSafeAndClosesConversationExactlyOnce() async {
        let conversation = ImmediateConversationSpy(providerID: .apple)
        let provider = ChatProviderSpy(
            id: .apple,
            conversation: conversation
        )
        let model = makeModel(provider: provider, preference: .apple)
        await model.bootstrap()

        async let first: Void = model.close()
        async let second: Void = model.close()
        _ = await (first, second)
        await model.close()

        let snapshot = await conversation.snapshot()
        XCTAssertEqual(snapshot.closeCount, 1)
        XCTAssertTrue(model.messages.isEmpty)
    }

    func testCloseRunsProviderCleanupBeforeAwaitingNonCooperativeResponse() async {
        let conversation = CloseReleasedConversationSpy()
        let provider = ChatProviderSpy(
            id: .ollama,
            conversation: conversation
        )
        let model = makeModel(provider: provider, preference: .ollama)
        await model.bootstrap()
        model.draft = "Release this through close"
        model.send()
        await conversation.waitUntilResponding()

        model.beginClose()

        guard await waitUntilConversationCloses(conversation) else {
            XCTFail("Provider close was blocked behind response completion")
            // Let the intentionally broken RED run unwind without leaking a
            // permanently suspended task into the rest of the suite.
            await conversation.close()
            await model.close()
            return
        }
        await model.close()

        let snapshot = await conversation.snapshot()
        XCTAssertEqual(snapshot.closeCount, 1)
        XCTAssertFalse(model.isSending)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertNil(model.availabilityNote)
    }

    func testResponseCompletingAfterCloseIsIgnored() async {
        let conversation = ControlledConversationSpy(providerID: .ollama)
        let provider = ChatProviderSpy(
            id: .ollama,
            conversation: conversation
        )
        let model = makeModel(provider: provider, preference: .ollama)
        await model.bootstrap()
        model.draft = "Will this be ignored?"
        model.send()
        await conversation.waitUntilResponding()

        model.beginClose()
        await conversation.complete(with: .success("Too late"))
        await model.close()

        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertFalse(model.isSending)
        XCTAssertNil(model.availabilityNote)
    }

    func testCloseRacingBootstrapClosesLateConversationOnce() async {
        let conversation = ImmediateConversationSpy(providerID: .ollama)
        let provider = ControlledCreationProvider(id: .ollama)
        let resolver = AIProviderResolver(
            apple: NeverAvailableProvider(id: .apple),
            ollama: provider
        )
        let model = AgentChatModel(
            server: makeServer(),
            resolver: resolver,
            preference: .ollama,
            ollamaModelID: "qwen3:4b"
        )
        let bootstrap = Task { await model.bootstrap() }
        await provider.waitUntilCreationStarts()

        model.beginClose()
        await provider.completeCreation(with: conversation)
        await bootstrap.value
        await model.close()

        let providerSnapshot = await provider.snapshot()
        let conversationSnapshot = await conversation.snapshot()
        XCTAssertEqual(providerSnapshot.creationModelIDs.count, 1)
        XCTAssertEqual(conversationSnapshot.closeCount, 1)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertNil(model.badgeText)
        XCTAssertNil(model.availabilityNote)
    }

    func testUnknownGenerationErrorUsesBoundedMessageWithoutSecret() async {
        let conversation = ImmediateConversationSpy(
            providerID: .ollama,
            responseError: AgentChatSyntheticError.secretBearing
        )
        let provider = ChatProviderSpy(
            id: .ollama,
            conversation: conversation
        )
        let model = makeModel(provider: provider, preference: .ollama)
        await model.bootstrap()
        model.draft = "Question"

        model.send()
        await waitUntil { !model.isSending }

        let systemMessages = model.messages.filter { $0.role == .system }
        XCTAssertEqual(
            systemMessages.last?.text,
            "The local model could not complete the request."
        )
        XCTAssertFalse(model.messages.contains {
            $0.text.contains("synthetic-secret")
        })
    }

    func testLocalGenerationErrorUsesActionableMessage() async {
        let conversation = ImmediateConversationSpy(
            providerID: .ollama,
            responseError: LocalAIError.timedOut
        )
        let provider = ChatProviderSpy(
            id: .ollama,
            conversation: conversation
        )
        let model = makeModel(provider: provider, preference: .ollama)
        await model.bootstrap()
        model.draft = "Question"

        model.send()
        await waitUntil { !model.isSending }

        XCTAssertEqual(
            model.messages.last?.text,
            "The local model took too long to respond."
        )
    }

    func testBootstrapCancellationAndUnknownErrorDoNotLeakDetails() async {
        let canceledConversation = ImmediateConversationSpy(providerID: .ollama)
        let canceledProvider = ChatProviderSpy(
            id: .ollama,
            conversation: canceledConversation,
            creationError: CancellationError()
        )
        let canceledModel = makeModel(
            provider: canceledProvider,
            preference: .ollama
        )

        await canceledModel.bootstrap()

        XCTAssertNil(canceledModel.availabilityNote)
        XCTAssertTrue(canceledModel.messages.isEmpty)

        let failedConversation = ImmediateConversationSpy(providerID: .ollama)
        let failedProvider = ChatProviderSpy(
            id: .ollama,
            conversation: failedConversation,
            creationError: AgentChatSyntheticError.secretBearing
        )
        let failedModel = makeModel(
            provider: failedProvider,
            preference: .ollama
        )

        await failedModel.bootstrap()

        XCTAssertEqual(failedModel.availabilityNote, "Local AI is unavailable.")
        XCTAssertFalse(
            failedModel.availabilityNote?.contains("synthetic-secret") == true
        )
    }

    private func makeModel(
        provider: any LocalAIProvider,
        preference: LocalAIProviderPreference,
        ollamaModelID: String = "qwen3:4b"
    ) -> AgentChatModel {
        AgentChatModel(
            server: makeServer(),
            resolver: AIProviderResolver(
                apple: preference == .apple
                    ? provider
                    : NeverAvailableProvider(id: .apple),
                ollama: preference == .ollama
                    ? provider
                    : NeverAvailableProvider(id: .ollama)
            ),
            preference: preference,
            ollamaModelID: ollamaModelID
        )
    }

    private func makeServer(
        arguments: [String] = ["node", "app.js", "--port", "3000"]
    ) -> DevServer {
        let processID = Int32(ProcessInfo.processInfo.processIdentifier)
        return DevServer(
            listener: ListeningPort(port: 3000, pid: processID),
            details: ProcessDetails(
                pid: processID,
                parentPID: processID,
                executablePath: "/usr/local/bin/node",
                arguments: arguments,
                workingDirectory: "/tmp/SampleProject",
                startTime: nil
            ),
            project: ProjectInfo(
                name: "SampleProject",
                rootPath: "/tmp/SampleProject",
                framework: .node
            )
        )
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }

    private func waitUntilConversationCloses(
        _ conversation: CloseReleasedConversationSpy
    ) async -> Bool {
        for _ in 0..<1_000 {
            if await conversation.snapshot().closeCount > 0 { return true }
            await Task.yield()
        }
        return false
    }
}
