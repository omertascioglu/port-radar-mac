// Modification notice: Changed in 2026 for the Port Radar Offline fork's private local Ollama service.
import Foundation

struct OllamaProvider: LocalAIProvider {
    /// Acquires one lease on the fork's private local service.
    typealias LeaseAcquiring = @Sendable () async throws -> OllamaServiceLease

    let id: LocalAIProviderID = .ollama

    private let acquireLease: LeaseAcquiring
    private let makeClient: OllamaClientFactory

    init(
        acquireLease: @escaping LeaseAcquiring = {
            try await OllamaServiceManager.shared.acquire()
        },
        makeClient: @escaping OllamaClientFactory =
            PrivateServiceOllamaClient.factory
    ) {
        self.acquireLease = acquireLease
        self.makeClient = makeClient
    }

    /// Nothing starts the private service until a local model is chosen, and
    /// the lease borrowed to validate one is always released again: only a live
    /// conversation keeps the child service running.
    func availability(modelID: String?) async -> LocalAIAvailability {
        guard let modelID, !modelID.isEmpty else {
            return .unavailable(.ollamaModelRequired)
        }

        let lease: OllamaServiceLease
        do {
            lease = try await acquireLease()
        } catch {
            return .unavailable(Self.serviceFailure(error))
        }

        do {
            try await makeClient(lease).validateLocalModel(modelID)
            await lease.release()
            return .available
        } catch {
            await lease.release()
            return .unavailable(Self.validationFailure(error))
        }
    }

    /// Acquires the service lease the conversation will own, then proves the
    /// selected model is local against that lease's client. Every failure path
    /// releases the lease before it throws, so a rejected model never leaves
    /// the child service running.
    func makeConversation(
        context: SanitizedProcessContext,
        modelID: String?
    ) async throws -> any LocalAIConversation {
        guard let modelID, !modelID.isEmpty else {
            throw LocalAIError.ollamaModelRequired
        }

        let lease = try await acquireLease()
        let client = makeClient(lease)
        do {
            try Task.checkCancellation()
            try await client.validateLocalModel(modelID)
            try Task.checkCancellation()
        } catch {
            await lease.release()
            throw error
        }

        return OllamaConversation(
            client: client,
            lease: lease,
            modelID: modelID,
            context: context
        )
    }

    private static func serviceFailure(_ error: any Error) -> LocalAIError {
        (error as? LocalAIError) ?? .ollamaPrivateServiceUnavailable
    }

    private static func validationFailure(_ error: any Error) -> LocalAIError {
        (error as? LocalAIError) ?? .ollamaNotRunning
    }
}

/// Owns one lease on the private local service for the conversation's whole
/// life. Close cancels the active turn, waits for it to unwind, unloads the
/// model once, and only then releases the lease.
actor OllamaConversation: LocalAIConversation {
    nonisolated let providerID: LocalAIProviderID = .ollama

    private let client: any OllamaClientProtocol
    private let lease: OllamaServiceLease
    private let modelID: String
    private var messages: [OllamaChatMessage]
    private var didStartChatRequest = false
    private var isClosed = false
    private var responseInProgress = false
    private var responseWaiters: [CheckedContinuation<Void, any Error>] = []
    private var activeRequestID: UUID?
    private var activeRequest: Task<LocalAITextStream, any Error>?
    private var activeForwarding: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var didFinishClose = false

    init(
        client: any OllamaClientProtocol,
        lease: OllamaServiceLease,
        modelID: String,
        context: SanitizedProcessContext
    ) {
        self.client = client
        self.lease = lease
        self.modelID = modelID
        self.messages = [
            .init(
                role: "system",
                content: LocalAIPrompt.instructions(context: context)
            ),
        ]
    }

    #if DEBUG
    /// The history a future turn would send. A partial or failed reply never
    /// appears here.
    func committedMessagesForTesting() -> [OllamaChatMessage] { messages }
    #endif

    /// Revalidates the selected model, opens one chat stream, and forwards its
    /// chunks live. The turn stays held until the forwarded stream ends, so a
    /// queued caller can only ever see committed history.
    func streamResponse(to prompt: String) async throws -> LocalAITextStream {
        try await acquireResponseTurn()

        let candidate = messages + [
            OllamaChatMessage(role: "user", content: prompt),
        ]
        let requestID = UUID()
        let source: LocalAITextStream
        do {
            try Task.checkCancellation()
            guard !isClosed else { throw CancellationError() }
            source = try await openChat(
                requestID: requestID,
                candidate: candidate
            )
        } catch {
            releaseResponseTurn()
            throw error
        }

        return forwarding(
            source,
            requestID: requestID,
            candidate: candidate
        )
    }

    func close() async {
        if didFinishClose { return }
        if let closeTask {
            await closeTask.value
            return
        }

        isClosed = true

        let waiters = responseWaiters
        responseWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: CancellationError()) }

        let request = activeRequest
        let forwardingTask = activeForwarding
        request?.cancel()
        forwardingTask?.cancel()
        let shouldUnload = didStartChatRequest
        let client = client
        let modelID = modelID
        let lease = lease
        let cleanup = Task {
            if let request {
                _ = await request.result
            }
            if let forwardingTask {
                await forwardingTask.value
            }
            if shouldUnload {
                await client.unload(model: modelID)
            }
            await lease.release()
        }
        closeTask = cleanup
        await cleanup.value
        didFinishClose = true
        closeTask = nil
    }

    /// Validates the model and opens the chat stream as one cancelable unit, so
    /// close can interrupt either half.
    private func openChat(
        requestID: UUID,
        candidate: [OllamaChatMessage]
    ) async throws -> LocalAITextStream {
        let client = client
        let modelID = modelID
        let request = Task<LocalAITextStream, any Error> { [self] in
            try Task.checkCancellation()
            try await client.validateLocalModel(modelID)
            try Task.checkCancellation()
            try authorizeChatStart(requestID: requestID)
            try Task.checkCancellation()
            return try await client.chatStream(
                model: modelID,
                messages: candidate
            )
        }
        activeRequestID = requestID
        activeRequest = request

        do {
            let source = try await withTaskCancellationHandler {
                try await request.value
            } onCancel: {
                request.cancel()
            }

            activeRequest = nil
            try Task.checkCancellation()
            guard !isClosed, activeRequestID == requestID else {
                throw CancellationError()
            }
            return source
        } catch {
            clearActiveTurn(requestID: requestID)
            if isClosed || Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    /// Hands every chunk to the consumer as it arrives while aggregating the
    /// same text for history. Cancellation or failure ends the turn without
    /// committing anything.
    private func forwarding(
        _ source: LocalAITextStream,
        requestID: UUID,
        candidate: [OllamaChatMessage]
    ) -> LocalAITextStream {
        let (stream, continuation) = LocalAITextStream.makeStream()
        let forwardingTask = Task { [self] in
            var reply = ""
            do {
                for try await chunk in source {
                    try Task.checkCancellation()
                    guard !isClosed, activeRequestID == requestID else {
                        throw CancellationError()
                    }
                    reply += chunk
                    continuation.yield(chunk)
                }
                try Task.checkCancellation()
                guard !isClosed, activeRequestID == requestID else {
                    throw CancellationError()
                }
                finishTurn(
                    requestID: requestID,
                    candidate: candidate,
                    reply: reply
                )
                continuation.finish()
            } catch {
                let wasClosed = isClosed
                finishTurn(
                    requestID: requestID,
                    candidate: candidate,
                    reply: nil
                )
                continuation.finish(
                    throwing: Self.terminalFailure(error, wasClosed: wasClosed)
                )
            }
        }
        continuation.onTermination = { _ in forwardingTask.cancel() }
        activeForwarding = forwardingTask
        return stream
    }

    /// Ends one turn exactly once: only a complete reply from the still-owned
    /// request becomes future history, and the next queued caller is admitted.
    private func finishTurn(
        requestID: UUID,
        candidate: [OllamaChatMessage],
        reply: String?
    ) {
        let isOwned = activeRequestID == requestID
        clearActiveTurn(requestID: requestID)
        if let reply, isOwned, !isClosed {
            messages = candidate + [
                OllamaChatMessage(role: "assistant", content: reply),
            ]
        }
        releaseResponseTurn()
    }

    private static func terminalFailure(
        _ error: any Error,
        wasClosed: Bool
    ) -> any Error {
        if wasClosed || error is CancellationError {
            return CancellationError()
        }
        return error
    }

    private func authorizeChatStart(requestID: UUID) throws {
        try Task.checkCancellation()
        guard !isClosed, activeRequestID == requestID else {
            throw CancellationError()
        }
        didStartChatRequest = true
    }

    private func clearActiveTurn(requestID: UUID) {
        guard activeRequestID == requestID else { return }
        activeRequestID = nil
        activeRequest = nil
        activeForwarding = nil
    }

    private func acquireResponseTurn() async throws {
        guard !isClosed else { throw CancellationError() }
        guard responseInProgress else {
            responseInProgress = true
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            responseWaiters.append(continuation)
        }
    }

    private func releaseResponseTurn() {
        guard !responseWaiters.isEmpty else {
            responseInProgress = false
            return
        }
        responseWaiters.removeFirst().resume()
    }
}
