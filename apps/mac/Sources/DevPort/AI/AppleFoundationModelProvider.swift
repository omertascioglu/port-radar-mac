import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

struct AppleFoundationModelProvider: LocalAIProvider {
    let id: LocalAIProviderID = .apple

    func availability(modelID: String?) async -> LocalAIAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return AppleFoundationModelAvailability.current
        }
        #endif
        return .unavailable(.appleUnavailable(
            "Apple Intelligence requires macOS 26 or later."
        ))
    }

    func makeConversation(
        context: SanitizedProcessContext,
        modelID: String?
    ) async throws -> any LocalAIConversation {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch AppleFoundationModelAvailability.current {
            case .available:
                return AppleFoundationModelConversation(
                    session: AppleFoundationModelSession(context: context)
                )
            case .unavailable(let error):
                throw error
            }
        }
        #endif
        throw LocalAIError.appleUnavailable(
            "Apple Intelligence requires macOS 26 or later."
        )
    }
}

protocol AppleModelSession: Sendable {
    func respond(to prompt: String) async throws -> String
    func close() async
}

actor AppleFoundationModelConversation: LocalAIConversation {
    nonisolated let providerID: LocalAIProviderID = .apple

    private var session: (any AppleModelSession)?
    private var isClosed = false
    private var responseInProgress = false
    private var responseWaiters: [CheckedContinuation<Void, any Error>] = []
    private var activeRequestID: UUID?
    private var activeRequest: Task<String, any Error>?
    private var closeTask: Task<Void, Never>?
    private var didFinishClose = false

    init(session: any AppleModelSession) {
        self.session = session
    }

    func respond(to prompt: String) async throws -> String {
        try await acquireResponseTurn()
        defer { releaseResponseTurn() }

        try Task.checkCancellation()
        guard !isClosed, let session else { throw CancellationError() }

        let requestID = UUID()
        let request = Task { [self] in
            try Task.checkCancellation()
            try authorizeRequest(requestID)
            let response = try await session.respond(to: prompt)
            try Task.checkCancellation()
            try authorizeRequest(requestID)
            return response
        }
        activeRequestID = requestID
        activeRequest = request

        do {
            let response = try await withTaskCancellationHandler {
                try await request.value
            } onCancel: {
                request.cancel()
            }
            try authorizeRequest(requestID)
            clearActiveRequest(requestID)
            return response
        } catch {
            clearActiveRequest(requestID)
            if isClosed || Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
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
        request?.cancel()
        let session = session
        let cleanup = Task {
            if let request {
                _ = await request.result
            }
            await session?.close()
        }
        closeTask = cleanup
        await cleanup.value
        self.session = nil
        didFinishClose = true
        closeTask = nil
    }

    private func authorizeRequest(_ requestID: UUID) throws {
        try Task.checkCancellation()
        guard !isClosed, activeRequestID == requestID else {
            throw CancellationError()
        }
    }

    private func clearActiveRequest(_ requestID: UUID) {
        guard activeRequestID == requestID else { return }
        activeRequestID = nil
        activeRequest = nil
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

#if canImport(FoundationModels)
@available(macOS 26.0, *)
private enum AppleFoundationModelAvailability {
    static var current: LocalAIAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable(.appleUnavailable(
                    "This Mac doesn’t support Apple Intelligence."
                ))
            case .appleIntelligenceNotEnabled:
                return .unavailable(.appleUnavailable(
                    "Turn on Apple Intelligence in System Settings to use Ask."
                ))
            case .modelNotReady:
                return .unavailable(.appleUnavailable(
                    "Apple Intelligence is still downloading or preparing. Try again shortly."
                ))
            @unknown default:
                return .unavailable(.appleUnavailable(
                    "Apple Intelligence isn’t available right now."
                ))
            }
        }
    }
}

@available(macOS 26.0, *)
private actor AppleFoundationModelSession: AppleModelSession {
    private var session: LanguageModelSession?

    init(context: SanitizedProcessContext) {
        session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: LocalAIPrompt.instructions(context: context)
        )
    }

    func respond(to prompt: String) async throws -> String {
        guard let session else { throw CancellationError() }
        return try await session.respond(to: prompt).content
    }

    func close() async {
        session = nil
    }
}
#endif
