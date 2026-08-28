// Modification notice: Changed in 2026 for the local AI and optional Ollama fallback contribution, and for the Port Radar Offline fork product identity.
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

private let leasedEndpoint = OllamaServiceEndpoint(
    baseURL: URL(string: "http://127.0.0.1:11435")!,
    processIdentifier: 4242
)

/// One finished reply delivered as a single streamed chunk.
private func finishedTextStream(_ text: String) -> LocalAITextStream {
    LocalAITextStream { continuation in
        continuation.yield(text)
        continuation.finish()
    }
}

/// Aggregates a streamed reply the way every consumer must: a consumer that is
/// cancelled mid-stream sees `CancellationError`, never a partial reply.
private func aggregated(
    _ stream: LocalAITextStream,
    into collector: ChunkCollector? = nil
) async throws -> String {
    var reply = ""
    for try await chunk in stream {
        try Task.checkCancellation()
        reply += chunk
        if let collector {
            await collector.append(chunk)
        }
    }
    try Task.checkCancellation()
    return reply
}

private func respond(
    _ conversation: OllamaConversation,
    to prompt: String
) async throws -> String {
    try await aggregated(conversation.streamResponse(to: prompt))
}

private actor ChunkCollector {
    private var chunks: [String] = []
    private var waiters:
        [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func append(_ chunk: String) {
        chunks.append(chunk)
        var remaining:
            [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if chunks.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }

    func waitUntilCount(_ count: Int) async {
        guard chunks.count < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    func collected() -> [String] { chunks }
}

/// Orders the observable service-lifetime events of one conversation.
private actor ServiceEventLog {
    private var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func recorded() -> [String] { events }
}

private struct LeaseSnapshot: Equatable, Sendable {
    let acquires: Int
    let releases: Int
}

private actor ServiceLeaseSpy {
    private let log: ServiceEventLog?
    private let acquireFailure: (any Error & Sendable)?
    private var acquires = 0
    private var releases = 0

    init(
        log: ServiceEventLog? = nil,
        acquireFailure: (any Error & Sendable)? = nil
    ) {
        self.log = log
        self.acquireFailure = acquireFailure
    }

    func acquire() async throws -> OllamaServiceLease {
        acquires += 1
        if let acquireFailure { throw acquireFailure }
        return OllamaServiceLease.testInstance(endpoint: leasedEndpoint) {
            await self.recordRelease()
        }
    }

    func snapshot() -> LeaseSnapshot {
        LeaseSnapshot(acquires: acquires, releases: releases)
    }

    private func recordRelease() async {
        releases += 1
        await log?.record("release")
    }
}

private struct LeaseBinding: Equatable, Sendable {
    let processIdentifier: Int32
    let modelID: String
}

private actor LeaseBindingRecorder {
    private var bindings: [LeaseBinding] = []

    func record(_ binding: LeaseBinding) {
        bindings.append(binding)
    }

    func recorded() -> [LeaseBinding] { bindings }
}

/// A client that can only answer for the lease it was built from, so a test can
/// prove validation ran against the lease-bound client.
private struct LeaseBoundClientStub: OllamaClientProtocol {
    let endpoint: OllamaServiceEndpoint
    let recorder: LeaseBindingRecorder
    let validationError: (any Error & Sendable)?

    init(
        endpoint: OllamaServiceEndpoint,
        recorder: LeaseBindingRecorder,
        validationError: (any Error & Sendable)? = nil
    ) {
        self.endpoint = endpoint
        self.recorder = recorder
        self.validationError = validationError
    }

    func version() async throws -> String { "test" }
    func localModels() async throws -> [OllamaModel] { [] }

    func validateLocalModel(_ id: String) async throws {
        await recorder.record(
            LeaseBinding(
                processIdentifier: endpoint.processIdentifier,
                modelID: id
            )
        )
        if let validationError { throw validationError }
    }

    func chatStream(
        model: String,
        messages: [OllamaChatMessage]
    ) async throws -> LocalAITextStream {
        finishedTextStream("Local answer")
    }

    func unload(model: String) async {}
}

private struct ControlledStreamSnapshot: Equatable, Sendable {
    let validationModelIDs: [String]
    let chatModelIDs: [String]
    let chatMessages: [[OllamaChatMessage]]
    let unloadModelIDs: [String]
    let cancelledSources: Int
}

/// Hands each chat turn a stream the test drives record by record, so nothing
/// depends on timing.
private actor ControlledStreamClient: OllamaClientProtocol {
    private let log: ServiceEventLog?
    private var validationResults: [ClientValidationResult]
    private var validationModelIDs: [String] = []
    private var chatModelIDs: [String] = []
    private var chatMessages: [[OllamaChatMessage]] = []
    private var unloadModelIDs: [String] = []
    private var cancelledSources = 0
    private var continuations: [LocalAITextStream.Continuation] = []
    private var chatCountWaiters:
        [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var cancellationWaiters:
        [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(
        validationResults: [ClientValidationResult] = [],
        log: ServiceEventLog? = nil
    ) {
        self.validationResults = validationResults
        self.log = log
    }

    func version() async throws -> String { "test" }
    func localModels() async throws -> [OllamaModel] { [] }

    func validateLocalModel(_ id: String) async throws {
        validationModelIDs.append(id)
        guard !validationResults.isEmpty else { return }
        switch validationResults.removeFirst() {
        case .success:
            return
        case .localError(let error):
            throw error
        case .unknownError:
            throw SyntheticClientError.failed
        }
    }

    func chatStream(
        model: String,
        messages: [OllamaChatMessage]
    ) async throws -> LocalAITextStream {
        chatModelIDs.append(model)
        chatMessages.append(messages)
        let (stream, continuation) = LocalAITextStream.makeStream()
        continuation.onTermination = { reason in
            guard case .cancelled = reason else { return }
            Task { await self.recordCancelledSource() }
        }
        continuations.append(continuation)
        resumeChatCountWaiters()
        return stream
    }

    func unload(model: String) async {
        unloadModelIDs.append(model)
        await log?.record("unload")
    }

    func emit(_ chunk: String) {
        continuations.last?.yield(chunk)
    }

    func completeNextChat(with result: Result<String, SyntheticClientError>) {
        switch result {
        case .success(let reply):
            continuations.last?.yield(reply)
            continuations.last?.finish()
        case .failure(let error):
            continuations.last?.finish(throwing: error)
        }
    }

    func finishStream() {
        continuations.last?.finish()
    }

    func failStream() {
        continuations.last?.finish(throwing: SyntheticClientError.failed)
    }

    func waitUntilChatCount(_ count: Int) async {
        guard chatMessages.count < count else { return }
        await withCheckedContinuation { continuation in
            chatCountWaiters.append((count, continuation))
        }
    }

    func waitUntilCancelledSourceCount(_ count: Int) async {
        guard cancelledSources < count else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append((count, continuation))
        }
    }

    func snapshot() -> ControlledStreamSnapshot {
        ControlledStreamSnapshot(
            validationModelIDs: validationModelIDs,
            chatModelIDs: chatModelIDs,
            chatMessages: chatMessages,
            unloadModelIDs: unloadModelIDs,
            cancelledSources: cancelledSources
        )
    }

    private func recordCancelledSource() {
        cancelledSources += 1
        var remaining:
            [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in cancellationWaiters {
            if cancelledSources >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        cancellationWaiters = remaining
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

private struct LifecycleClientSnapshot: Equatable, Sendable {
    let validationCalls: Int
    let chatCalls: Int
    let validationCancellationCount: Int
    let chatCancellationCount: Int
    let unloadModelIDs: [String]
}

private actor ControlledChatLifecycleClient: OllamaClientProtocol {
    private let log: ServiceEventLog?
    private var chatCalls = 0
    private var chatCancellationCount = 0
    private var unloadModelIDs: [String] = []
    private var chatContinuation: CheckedContinuation<String, any Error>?
    private var chatStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var lifecycleWaiters: [CheckedContinuation<Void, Never>] = []

    init(log: ServiceEventLog? = nil) {
        self.log = log
    }

    func version() async throws -> String { "test" }
    func localModels() async throws -> [OllamaModel] { [] }
    func validateLocalModel(_ id: String) async throws {}

    func chatStream(
        model: String,
        messages: [OllamaChatMessage]
    ) async throws -> LocalAITextStream {
        chatCalls += 1
        let waiters = chatStartWaiters
        chatStartWaiters.removeAll()
        waiters.forEach { $0.resume() }

        let reply = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                chatContinuation = continuation
            }
        } onCancel: {
            Task { await self.recordChatCancellation() }
        }
        return finishedTextStream(reply)
    }

    func unload(model: String) async {
        unloadModelIDs.append(model)
        await log?.record("unload")
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
    private let log: ServiceEventLog?
    private var validationCalls = 0
    private var chatCalls = 0
    private var validationCancellationCount = 0
    private var unloadModelIDs: [String] = []
    private var validationContinuation: CheckedContinuation<Void, any Error>?
    private var requestStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var lifecycleWaiters: [CheckedContinuation<Void, Never>] = []

    init(log: ServiceEventLog? = nil) {
        self.log = log
    }

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

    func chatStream(
        model: String,
        messages: [OllamaChatMessage]
    ) async throws -> LocalAITextStream {
        chatCalls += 1
        signalRequestStarted()
        return finishedTextStream("Privacy boundary bypassed")
    }

    func unload(model: String) async {
        unloadModelIDs.append(model)
        await log?.record("unload")
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

    // MARK: - Service ownership

    func testAvailabilityRequiresNonemptyModelBeforeTouchingTheService() async {
        let leases = ServiceLeaseSpy()
        let provider = makeProvider(leases: leases, client: ControlledStreamClient())

        let missing = await provider.availability(modelID: nil)
        let empty = await provider.availability(modelID: "")

        XCTAssertEqual(missing, .unavailable(.ollamaModelRequired))
        XCTAssertEqual(empty, .unavailable(.ollamaModelRequired))
        let snapshot = await leases.snapshot()
        XCTAssertEqual(snapshot, LeaseSnapshot(acquires: 0, releases: 0))
    }

    func testAvailabilityReleasesTheLeaseItAcquiredToValidate() async {
        let leases = ServiceLeaseSpy()
        let client = ControlledStreamClient()
        let provider = makeProvider(leases: leases, client: client)

        let availability = await provider.availability(modelID: modelID)

        XCTAssertEqual(availability, .available)
        let leaseSnapshot = await leases.snapshot()
        XCTAssertEqual(leaseSnapshot, LeaseSnapshot(acquires: 1, releases: 1))
        let clientSnapshot = await client.snapshot()
        XCTAssertEqual(clientSnapshot.validationModelIDs, [modelID])
    }

    func testAvailabilityPreservesLocalErrorAndStillReleasesTheLease() async {
        let leases = ServiceLeaseSpy()
        let client = ControlledStreamClient(
            validationResults: [.localError(.remoteModelRejected)]
        )
        let provider = makeProvider(leases: leases, client: client)

        let availability = await provider.availability(modelID: modelID)

        XCTAssertEqual(availability, .unavailable(.remoteModelRejected))
        let snapshot = await leases.snapshot()
        XCTAssertEqual(snapshot, LeaseSnapshot(acquires: 1, releases: 1))
    }

    func testAvailabilityMapsUnknownFailureToBoundedErrorAndReleases() async {
        let leases = ServiceLeaseSpy()
        let client = ControlledStreamClient(validationResults: [.unknownError])
        let provider = makeProvider(leases: leases, client: client)

        let availability = await provider.availability(modelID: modelID)

        XCTAssertEqual(availability, .unavailable(.ollamaNotRunning))
        XCTAssertFalse(String(describing: availability).contains("failed"))
        let snapshot = await leases.snapshot()
        XCTAssertEqual(snapshot, LeaseSnapshot(acquires: 1, releases: 1))
    }

    func testAvailabilitySurfacesServiceStartFailureWithoutValidating() async {
        let leases = ServiceLeaseSpy(
            acquireFailure: LocalAIError.ollamaPrivateServiceUnavailable
        )
        let client = ControlledStreamClient()
        let provider = makeProvider(leases: leases, client: client)

        let availability = await provider.availability(modelID: modelID)

        XCTAssertEqual(
            availability,
            .unavailable(.ollamaPrivateServiceUnavailable)
        )
        let clientSnapshot = await client.snapshot()
        XCTAssertTrue(clientSnapshot.validationModelIDs.isEmpty)
    }

    func testCreationRequiresNonemptyModelBeforeAcquiringTheService() async {
        let leases = ServiceLeaseSpy()
        let client = ControlledStreamClient()
        let provider = makeProvider(leases: leases, client: client)

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

        let leaseSnapshot = await leases.snapshot()
        let clientSnapshot = await client.snapshot()
        XCTAssertEqual(leaseSnapshot, LeaseSnapshot(acquires: 0, releases: 0))
        XCTAssertTrue(clientSnapshot.validationModelIDs.isEmpty)
    }

    func testCreationValidatesAgainstTheLeaseBoundClientAndKeepsTheLease() async throws {
        let leases = ServiceLeaseSpy()
        let bindings = LeaseBindingRecorder()
        let provider = OllamaProvider(
            acquireLease: { try await leases.acquire() },
            makeClient: { lease in
                LeaseBoundClientStub(
                    endpoint: lease.endpoint,
                    recorder: bindings
                )
            }
        )

        let conversation = try await provider.makeConversation(
            context: .init(text: "port: 3000"),
            modelID: modelID
        )

        XCTAssertEqual(conversation.providerID, .ollama)
        var recorded = await bindings.recorded()
        XCTAssertEqual(
            recorded,
            [
                LeaseBinding(
                    processIdentifier: leasedEndpoint.processIdentifier,
                    modelID: modelID
                ),
            ]
        )
        var leaseSnapshot = await leases.snapshot()
        XCTAssertEqual(leaseSnapshot, LeaseSnapshot(acquires: 1, releases: 0))

        let reply = try await aggregated(
            conversation.streamResponse(to: "Explain it")
        )
        XCTAssertEqual(reply, "Local answer")
        recorded = await bindings.recorded()
        XCTAssertEqual(recorded.count, 2)
        XCTAssertEqual(
            recorded[1].processIdentifier,
            leasedEndpoint.processIdentifier
        )

        await conversation.close()
        leaseSnapshot = await leases.snapshot()
        XCTAssertEqual(leaseSnapshot, LeaseSnapshot(acquires: 1, releases: 1))
    }

    func testCreationValidationFailureReleasesTheLeaseExactlyOnce() async {
        let leases = ServiceLeaseSpy()
        let bindings = LeaseBindingRecorder()
        let provider = OllamaProvider(
            acquireLease: { try await leases.acquire() },
            makeClient: { lease in
                LeaseBoundClientStub(
                    endpoint: lease.endpoint,
                    recorder: bindings,
                    validationError: LocalAIError.remoteModelRejected
                )
            }
        )

        do {
            _ = try await provider.makeConversation(
                context: .init(text: "port: 3000"),
                modelID: modelID
            )
            XCTFail("Expected the rejected model to fail creation")
        } catch {
            XCTAssertEqual(error as? LocalAIError, .remoteModelRejected)
        }

        let snapshot = await leases.snapshot()
        XCTAssertEqual(snapshot, LeaseSnapshot(acquires: 1, releases: 1))
    }

    func testCreationSurfacesServiceStartFailureWithoutBuildingAClient() async {
        let leases = ServiceLeaseSpy(
            acquireFailure: LocalAIError.ollamaPrivateServiceUnavailable
        )
        let bindings = LeaseBindingRecorder()
        let provider = OllamaProvider(
            acquireLease: { try await leases.acquire() },
            makeClient: { lease in
                LeaseBoundClientStub(
                    endpoint: lease.endpoint,
                    recorder: bindings
                )
            }
        )

        do {
            _ = try await provider.makeConversation(
                context: .init(text: "port: 3000"),
                modelID: modelID
            )
            XCTFail("Expected the private service failure to surface")
        } catch {
            XCTAssertEqual(
                error as? LocalAIError,
                .ollamaPrivateServiceUnavailable
            )
        }

        let recorded = await bindings.recorded()
        let snapshot = await leases.snapshot()
        XCTAssertTrue(recorded.isEmpty)
        XCTAssertEqual(snapshot, LeaseSnapshot(acquires: 1, releases: 0))
    }

    // MARK: - Streaming

    func testConversationStartsWithExactProviderNeutralSystemPrompt() async throws {
        let client = ControlledStreamClient()
        let conversation = try await makeConversation(
            client: client,
            context: .init(
                text: "port: 3000\ncommand: tool --token=[REDACTED]"
            )
        )
        let response = Task { try await respond(conversation, to: "Explain it") }

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
                    You are a concise assistant inside Port Radar Offline, a macOS menu-bar app that lists localhost listeners.
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
        await conversation.close()
    }

    func testChunksReachTheConsumerBeforeTheReplyIsCommitted() async throws {
        let client = ControlledStreamClient()
        let conversation = try await makeConversation(client: client)
        let collector = ChunkCollector()

        let stream = try await conversation.streamResponse(to: "Explain it")
        let consumer = Task { try await aggregated(stream, into: collector) }
        await client.emit("Hel")
        await collector.waitUntilCount(1)

        let firstChunks = await collector.collected()
        XCTAssertEqual(firstChunks, ["Hel"])
        let midStream = await conversation.committedMessagesForTesting()
        XCTAssertEqual(midStream.map(\.role), ["system"])

        await client.emit("lo")
        await client.finishStream()
        let reply = try await consumer.value

        XCTAssertEqual(reply, "Hello")
        let allChunks = await collector.collected()
        XCTAssertEqual(allChunks, ["Hel", "lo"])
        let committed = await conversation.committedMessagesForTesting()
        XCTAssertEqual(committed.map(\.role), ["system", "user", "assistant"])
        XCTAssertEqual(committed.last?.content, "Hello")
        await conversation.close()
    }

    func testSuccessfulResponseCommitsUserAndAssistantMessages() async throws {
        let client = ControlledStreamClient()
        let conversation = try await makeConversation(client: client)

        let first = Task { try await respond(conversation, to: "First question") }
        await client.waitUntilChatCount(1)
        await client.completeNextChat(with: .success("First answer"))
        let firstAnswer = try await first.value
        XCTAssertEqual(firstAnswer, "First answer")

        let second = Task { try await respond(conversation, to: "Second question") }
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
        await conversation.close()
    }

    func testFailedPartialResponseIsNotCommittedToFutureHistory() async throws {
        let leases = ServiceLeaseSpy()
        let client = ControlledStreamClient()
        let conversation = try await makeConversation(
            client: client,
            leases: leases
        )

        let stream = try await conversation.streamResponse(to: "Failed question")
        let failed = Task { try await aggregated(stream) }
        await client.emit("Partial answer")
        await client.failStream()
        do {
            _ = try await failed.value
            XCTFail("Expected the first response to fail")
        } catch SyntheticClientError.failed {
            // Expected.
        }

        let afterFailure = await conversation.committedMessagesForTesting()
        XCTAssertEqual(afterFailure.map(\.role), ["system"])

        let retry = Task { try await respond(conversation, to: "Retry question") }
        await client.waitUntilChatCount(2)
        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.chatMessages[1].map(\.role), ["system", "user"])
        XCTAssertEqual(snapshot.chatMessages[1].last?.content, "Retry question")
        XCTAssertFalse(
            snapshot.chatMessages[1].contains(where: {
                $0.content.contains("Failed question")
                    || $0.content.contains("Partial answer")
            })
        )
        await client.completeNextChat(with: .success("Recovered"))
        _ = try await retry.value

        await conversation.close()

        let leaseSnapshot = await leases.snapshot()
        XCTAssertEqual(leaseSnapshot, LeaseSnapshot(acquires: 1, releases: 1))
    }

    func testConsumerCancelledMidStreamCommitsNothingAndFreesTheTurn() async throws {
        let leases = ServiceLeaseSpy()
        let client = ControlledStreamClient()
        let conversation = try await makeConversation(
            client: client,
            leases: leases
        )
        let collector = ChunkCollector()

        let stream = try await conversation.streamResponse(to: "First question")
        let consumer = Task { try await aggregated(stream, into: collector) }
        await client.emit("Partial answer")
        await collector.waitUntilCount(1)
        consumer.cancel()

        do {
            _ = try await consumer.value
            XCTFail("Expected the cancelled consumer to fail")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        await client.waitUntilCancelledSourceCount(1)
        let afterCancellation = await conversation.committedMessagesForTesting()
        XCTAssertEqual(afterCancellation.map(\.role), ["system"])

        let second = Task { try await respond(conversation, to: "Second question") }
        await client.waitUntilChatCount(2)
        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.chatMessages[1].map(\.role), ["system", "user"])
        XCTAssertFalse(
            snapshot.chatMessages[1].contains(where: {
                $0.content.contains("Partial answer")
                    || $0.content.contains("First question")
            })
        )
        await client.completeNextChat(with: .success("Second answer"))
        let secondAnswer = try await second.value
        XCTAssertEqual(secondAnswer, "Second answer")

        await conversation.close()

        let leaseSnapshot = await leases.snapshot()
        XCTAssertEqual(leaseSnapshot, LeaseSnapshot(acquires: 1, releases: 1))
    }

    func testEveryResponseRevalidatesAndDoesNotChatAfterModelBecomesRemote() async throws {
        let client = ControlledStreamClient(validationResults: [
            .success,
            .localError(.remoteModelRejected),
        ])
        let conversation = try await makeConversation(
            client: client,
            context: .init(text: "sanitized-only-context")
        )

        let first = Task { try await respond(conversation, to: "First question") }
        await client.waitUntilChatCount(1)
        await client.completeNextChat(with: .success("Local answer"))
        let firstAnswer = try await first.value
        XCTAssertEqual(firstAnswer, "Local answer")

        do {
            _ = try await respond(conversation, to: "Blocked question")
            XCTFail("Expected the model change to block chat")
        } catch {
            XCTAssertEqual(error as? LocalAIError, .remoteModelRejected)
        }

        let snapshot = await client.snapshot()
        XCTAssertEqual(
            snapshot.validationModelIDs,
            [modelID, modelID]
        )
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
        await conversation.close()
    }

    func testConcurrentResponsesAreSerializedAndUseCommittedHistory() async throws {
        let client = ControlledStreamClient()
        let conversation = try await makeConversation(client: client)

        let first = Task { try await respond(conversation, to: "First question") }
        await client.waitUntilChatCount(1)
        let secondStarted = expectation(description: "second task started")
        let second = Task {
            secondStarted.fulfill()
            return try await respond(conversation, to: "Second question")
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
        await conversation.close()
    }

    func testQueuedResponseIsIndependentlyCancelableWithoutStartingAChat() async throws {
        let client = ControlledStreamClient()
        let conversation = try await makeConversation(client: client)

        let first = Task { try await respond(conversation, to: "First question") }
        await client.waitUntilChatCount(1)
        let queuedStarted = expectation(description: "queued task started")
        let queued = Task {
            queuedStarted.fulfill()
            return try await respond(conversation, to: "Queued question")
        }
        await fulfillment(of: [queuedStarted], timeout: 1)
        for _ in 0..<20 { await Task.yield() }
        queued.cancel()

        await client.completeNextChat(with: .success("First answer"))
        let firstAnswer = try await first.value
        XCTAssertEqual(firstAnswer, "First answer")

        do {
            _ = try await queued.value
            XCTFail("Expected the queued response to cancel")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        var snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.chatMessages.count, 1)
        XCTAssertFalse(
            snapshot.chatMessages.flatMap { $0 }.contains(where: {
                $0.content.contains("Queued question")
            })
        )

        let survivor = Task { try await respond(conversation, to: "Survivor") }
        await client.waitUntilChatCount(2)
        await client.completeNextChat(with: .success("Survivor answer"))
        let survivorAnswer = try await survivor.value
        XCTAssertEqual(survivorAnswer, "Survivor answer")
        snapshot = await client.snapshot()
        XCTAssertEqual(
            snapshot.chatMessages[1].map(\.content).suffix(3),
            ["First question", "First answer", "Survivor"]
        )
        await conversation.close()
    }

    // MARK: - Close

    func testCloseCancelsAnOpenStreamThenUnloadsBeforeReleasingTheLease() async throws {
        let log = ServiceEventLog()
        let leases = ServiceLeaseSpy(log: log)
        let client = ControlledStreamClient(log: log)
        let conversation = try await makeConversation(
            client: client,
            leases: leases
        )

        let stream = try await conversation.streamResponse(to: "Question")
        let consumer = Task { try await aggregated(stream) }
        await client.emit("Partial answer")

        await conversation.close()
        await conversation.close()

        do {
            _ = try await consumer.value
            XCTFail("Expected close to cancel the open stream")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        await client.waitUntilCancelledSourceCount(1)
        let events = await log.recorded()
        let leaseSnapshot = await leases.snapshot()
        XCTAssertEqual(events, ["unload", "release"])
        XCTAssertEqual(leaseSnapshot, LeaseSnapshot(acquires: 1, releases: 1))
        let clientSnapshot = await client.snapshot()
        XCTAssertEqual(clientSnapshot.unloadModelIDs, [modelID])
        XCTAssertEqual(clientSnapshot.cancelledSources, 1)
        let committed = await conversation.committedMessagesForTesting()
        XCTAssertEqual(committed.map(\.role), ["system"])
    }

    func testCloseAwaitsCancelledChatBeforeUnloadingExactlyOnce() async throws {
        let log = ServiceEventLog()
        let leases = ServiceLeaseSpy(log: log)
        let client = ControlledChatLifecycleClient(log: log)
        let conversation = OllamaConversation(
            client: client,
            lease: try await leases.acquire(),
            modelID: modelID,
            context: .init(text: "port: 3000")
        )
        let response = Task { try await respond(conversation, to: "Question") }
        await client.waitUntilChatStarts()

        let firstClose = Task { await conversation.close() }
        let secondClose = Task { await conversation.close() }
        await client.waitUntilCancellationOrUnload()

        var snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.chatCancellationCount, 1)
        XCTAssertTrue(snapshot.unloadModelIDs.isEmpty)
        let leaseSnapshotBeforeClose = await leases.snapshot()
        XCTAssertEqual(
            leaseSnapshotBeforeClose,
            LeaseSnapshot(acquires: 1, releases: 0)
        )

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
        let events = await log.recorded()
        let leaseSnapshot = await leases.snapshot()
        XCTAssertEqual(events, ["unload", "release"])
        XCTAssertEqual(leaseSnapshot, LeaseSnapshot(acquires: 1, releases: 1))
    }

    func testCloseAwaitsCancelledValidationAndStillReleasesTheLease() async throws {
        let log = ServiceEventLog()
        let leases = ServiceLeaseSpy(log: log)
        let client = ControlledValidationLifecycleClient(log: log)
        let conversation = OllamaConversation(
            client: client,
            lease: try await leases.acquire(),
            modelID: modelID,
            context: .init(text: "port: 3000")
        )
        let response = Task { try await respond(conversation, to: "Question") }
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
        let events = await log.recorded()
        let leaseSnapshot = await leases.snapshot()
        XCTAssertEqual(events, ["release"])
        XCTAssertEqual(leaseSnapshot, LeaseSnapshot(acquires: 1, releases: 1))
    }

    func testCloseDuringRequestRejectsLateResponseAndUnloadsExactlyOnce() async throws {
        let log = ServiceEventLog()
        let leases = ServiceLeaseSpy(log: log)
        let client = ControlledChatLifecycleClient(log: log)
        let conversation = OllamaConversation(
            client: client,
            lease: try await leases.acquire(),
            modelID: modelID,
            context: .init(text: "port: 3000")
        )
        let response = Task { try await respond(conversation, to: "Question") }
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
            _ = try await respond(conversation, to: "After close")
            XCTFail("Expected closed conversation to reject future use")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.chatCalls, 1)
        XCTAssertEqual(snapshot.unloadModelIDs, [modelID])
        let events = await log.recorded()
        let leaseSnapshot = await leases.snapshot()
        XCTAssertEqual(events, ["unload", "release"])
        XCTAssertEqual(leaseSnapshot, LeaseSnapshot(acquires: 1, releases: 1))
    }

    func testCloseBeforeFirstRequestSkipsUnloadAndReleasesTheLeaseOnce() async throws {
        let log = ServiceEventLog()
        let leases = ServiceLeaseSpy(log: log)
        let client = ControlledStreamClient(log: log)
        let conversation = try await makeConversation(
            client: client,
            leases: leases
        )

        await conversation.close()
        await conversation.close()

        let snapshot = await client.snapshot()
        XCTAssertTrue(snapshot.chatMessages.isEmpty)
        XCTAssertTrue(snapshot.unloadModelIDs.isEmpty)
        let events = await log.recorded()
        let leaseSnapshot = await leases.snapshot()
        XCTAssertEqual(events, ["release"])
        XCTAssertEqual(leaseSnapshot, LeaseSnapshot(acquires: 1, releases: 1))
    }

    // MARK: - Helpers

    private func makeProvider(
        leases: ServiceLeaseSpy,
        client: any OllamaClientProtocol
    ) -> OllamaProvider {
        OllamaProvider(
            acquireLease: { try await leases.acquire() },
            makeClient: { _ in client }
        )
    }

    private func makeConversation(
        client: any OllamaClientProtocol,
        leases: ServiceLeaseSpy = ServiceLeaseSpy(),
        context: SanitizedProcessContext = .init(text: "port: 3000")
    ) async throws -> OllamaConversation {
        OllamaConversation(
            client: client,
            lease: try await leases.acquire(),
            modelID: modelID,
            context: context
        )
    }
}
