import Foundation
import os

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

private final class AppleResponseTurnGate: Sendable {
    private enum Registration {
        case registering
        case canceled
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var isClosed = false
        var isHeld = false
        // Keeps cancellation from being lost before a continuation is queued.
        var registrations: [UUID: Registration] = [:]
        var waiters: [Waiter] = []
    }

    private enum Admission {
        case acquired
        case queued
        case rejected
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func acquire() async throws {
        let id = UUID()
        try Task.checkCancellation()
        state.withLock { state in
            state.registrations[id] = .registering
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let admission = state.withLock { state -> Admission in
                    let registration = state.registrations.removeValue(
                        forKey: id
                    )
                    guard !state.isClosed,
                          registration == .registering,
                          !Task.isCancelled
                    else {
                        return .rejected
                    }
                    guard state.isHeld else {
                        state.isHeld = true
                        return .acquired
                    }
                    state.waiters.append(.init(
                        id: id,
                        continuation: continuation
                    ))
                    return .queued
                }

                switch admission {
                case .acquired:
                    continuation.resume()
                case .queued:
                    break
                case .rejected:
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            cancel(id: id)
        }
    }

    func release() {
        let continuation: CheckedContinuation<Void, any Error>? =
            state.withLock { state in
                guard !state.waiters.isEmpty else {
                    state.isHeld = false
                    return nil
                }
                return state.waiters.removeFirst().continuation
            }
        continuation?.resume()
    }

    func close() {
        let continuations: [CheckedContinuation<Void, any Error>] =
            state.withLock { state in
                guard !state.isClosed else { return [] }
                state.isClosed = true
                state.registrations = state.registrations.mapValues { _ in
                    .canceled
                }
                let continuations = state.waiters.map(\.continuation)
                state.waiters.removeAll()
                return continuations
            }
        continuations.forEach {
            $0.resume(throwing: CancellationError())
        }
    }

    private func cancel(id: UUID) {
        let continuation: CheckedContinuation<Void, any Error>? =
            state.withLock { state in
                if let index = state.waiters.firstIndex(where: {
                    $0.id == id
                }) {
                    return state.waiters.remove(at: index).continuation
                }
                if state.registrations[id] != nil {
                    state.registrations[id] = .canceled
                }
                return nil
            }
        continuation?.resume(throwing: CancellationError())
    }
}

actor AppleFoundationModelConversation: LocalAIConversation {
    nonisolated let providerID: LocalAIProviderID = .apple

    private var session: (any AppleModelSession)?
    private var isClosed = false
    private let responseTurnGate = AppleResponseTurnGate()
    private var activeRequestID: UUID?
    private var activeRequest: Task<String, any Error>?
    private var closeTask: Task<Void, Never>?
    private var didFinishClose = false

    init(session: any AppleModelSession) {
        self.session = session
    }

    /// Apple's session hands back one finished reply, so this wraps it as a
    /// single stream chunk instead of reaching for unverified streaming API.
    /// The lifecycle gate still serializes whole turns.
    func streamResponse(to prompt: String) async throws -> LocalAITextStream {
        let response = try await completeResponse(to: prompt)
        return LocalAITextStream { continuation in
            continuation.yield(response)
            continuation.finish()
        }
    }

    private func completeResponse(to prompt: String) async throws -> String {
        try await responseTurnGate.acquire()
        defer { responseTurnGate.release() }

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
        responseTurnGate.close()

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
