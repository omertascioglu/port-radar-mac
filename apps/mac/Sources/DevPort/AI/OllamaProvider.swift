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
    private var didStartRequest = false
    private var isClosed = false
    private var responseInProgress = false
    private var responseWaiters: [CheckedContinuation<Void, any Error>] = []

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
        didStartRequest = true
        let response = try await client.chat(
            model: modelID,
            messages: candidate
        )

        try Task.checkCancellation()
        guard !isClosed else { throw CancellationError() }
        messages = candidate + [
            OllamaChatMessage(role: "assistant", content: response),
        ]
        return response
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true

        let waiters = responseWaiters
        responseWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: CancellationError()) }

        if didStartRequest {
            await client.unload(model: modelID)
        }
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
