import Foundation

struct OllamaProvider: LocalAIProvider {
    let id: LocalAIProviderID = .ollama
    let client: any OllamaClientProtocol

    init(client: any OllamaClientProtocol = OllamaClient()) {
        self.client = client
    }

    func availability(modelID: String?) async -> LocalAIAvailability {
        guard let modelID, !modelID.isEmpty else {
            return .unavailable(.ollamaModelRequired)
        }
        do {
            try await client.validateLocalModel(modelID)
            return .available
        } catch let error as LocalAIError {
            return .unavailable(error)
        } catch {
            return .unavailable(.ollamaNotRunning)
        }
    }

    func makeConversation(
        context: SanitizedProcessContext,
        modelID: String?
    ) async throws -> any LocalAIConversation {
        guard let modelID, !modelID.isEmpty else {
            throw LocalAIError.ollamaModelRequired
        }
        try await client.validateLocalModel(modelID)
        return OllamaConversation(
            client: client,
            modelID: modelID,
            context: context
        )
    }
}

actor OllamaConversation: LocalAIConversation {
    nonisolated let providerID: LocalAIProviderID = .ollama

    private let client: any OllamaClientProtocol
    private let modelID: String
    private var messages: [OllamaChatMessage]
    private var didStartChatRequest = false
    private var isClosed = false
    private var responseInProgress = false
    private var responseWaiters: [CheckedContinuation<Void, any Error>] = []
    private var activeRequestID: UUID?
    private var activeRequest: Task<String, any Error>?
    private var closeTask: Task<Void, Never>?
    private var didFinishClose = false

    init(
        client: any OllamaClientProtocol,
        modelID: String,
        context: SanitizedProcessContext
    ) {
        self.client = client
        self.modelID = modelID
        self.messages = [
            .init(
                role: "system",
                content: LocalAIPrompt.instructions(context: context)
            ),
        ]
    }

    func respond(to prompt: String) async throws -> String {
        try await acquireResponseTurn()
        defer { releaseResponseTurn() }

        try Task.checkCancellation()
        guard !isClosed else { throw CancellationError() }

        let candidate = messages + [
            OllamaChatMessage(role: "user", content: prompt),
        ]
        let requestID = UUID()
        let client = client
        let modelID = modelID
        let request = Task { [self] in
            try Task.checkCancellation()
            try await client.validateLocalModel(modelID)
            try Task.checkCancellation()
            try authorizeChatStart(requestID: requestID)
            try Task.checkCancellation()
            return try await client.chat(
                model: modelID,
                messages: candidate
            )
        }
        activeRequestID = requestID
        activeRequest = request

        do {
            let response = try await withTaskCancellationHandler {
                try await request.value
            } onCancel: {
                request.cancel()
            }

            clearActiveRequest(requestID: requestID)
            try Task.checkCancellation()
            guard !isClosed else { throw CancellationError() }
            messages = candidate + [
                OllamaChatMessage(role: "assistant", content: response),
            ]
            return response
        } catch {
            clearActiveRequest(requestID: requestID)
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
        let shouldUnload = didStartChatRequest
        let client = client
        let modelID = modelID
        let cleanup = Task {
            if let request {
                _ = await request.result
            }
            if shouldUnload {
                await client.unload(model: modelID)
            }
        }
        closeTask = cleanup
        await cleanup.value
        didFinishClose = true
        closeTask = nil
    }

    private func authorizeChatStart(requestID: UUID) throws {
        try Task.checkCancellation()
        guard !isClosed, activeRequestID == requestID else {
            throw CancellationError()
        }
        didStartChatRequest = true
    }

    private func clearActiveRequest(requestID: UUID) {
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
