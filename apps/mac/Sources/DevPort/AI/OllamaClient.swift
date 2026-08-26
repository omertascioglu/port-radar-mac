// Modification notice: Changed in 2026 for the Port Radar Offline fork's private local Ollama service.
import Foundation

/// Incremental assistant text from a local model, in emission order.
typealias LocalAITextStream = AsyncThrowingStream<String, any Error>

protocol OllamaClientProtocol: Sendable {
    func version() async throws -> String
    func localModels() async throws -> [OllamaModel]
    func validateLocalModel(_ id: String) async throws
    func chatStream(
        model: String,
        messages: [OllamaChatMessage]
    ) async throws -> LocalAITextStream
    func unload(model: String) async
}

/// Builds a client bound to one owned lease on the fork's private service.
typealias OllamaClientFactory =
    @Sendable (OllamaServiceLease) -> any OllamaClientProtocol

/// Resolves a client bound to the private service, acquiring what it needs.
typealias OllamaClientProviding =
    @Sendable () async throws -> any OllamaClientProtocol

enum PrivateServiceOllamaClient {
    static let factory: OllamaClientFactory = { lease in
        OllamaClient(transport: OllamaTransport(lease: lease))
    }

    /// Interim, known leak: the lease acquired here is never released. Only
    /// the client escapes this closure, so nothing can call `release()` on it
    /// and the private service stays alive for the rest of the process.
    /// Conversations no longer take this path — they acquire and release their
    /// own lease — so the remaining leak is the settings-refresh call site,
    /// which is owned by Task 10.
    static let provider: OllamaClientProviding = {
        factory(try await OllamaServiceManager.shared.acquire())
    }
}

struct OllamaClient: OllamaClientProtocol, Sendable {
    let transport: any OllamaTransporting

    init(transport: any OllamaTransporting) {
        self.transport = transport
    }

    func version() async throws -> String {
        let data = try await request(
            path: "/api/version",
            method: "GET",
            body: nil
        )
        return try decode(OllamaVersionResponse.self, from: data).version
    }

    func localModels() async throws -> [OllamaModel] {
        let data = try await request(
            path: "/api/tags",
            method: "GET",
            body: nil
        )
        return try decode(OllamaTagsResponse.self, from: data)
            .validatedLocalModels
    }

    func validateLocalModel(_ id: String) async throws {
        guard try await localModels().contains(where: { $0.id == id }) else {
            throw LocalAIError.ollamaModelUnavailable
        }

        let data = try await request(
            path: "/api/show",
            method: "POST",
            body: try encode(["model": id])
        )
        guard try decode(OllamaShowResponse.self, from: data)
            .confirmsLocalExecution
        else {
            throw LocalAIError.remoteModelRejected
        }
    }

    /// Streams one chat turn. The model stays loaded for two minutes so it is
    /// never unloaded while the stream is still open, and the caller sees only
    /// assistant text — never a raw record, status, or server message.
    func chatStream(
        model: String,
        messages: [OllamaChatMessage]
    ) async throws -> LocalAITextStream {
        let chatRequest = OllamaChatRequest(
            model: model,
            messages: messages,
            stream: true,
            keepAlive: .duration("2m")
        )
        let body = try encode(chatRequest)
        let records: AsyncThrowingStream<Data, any Error>
        do {
            records = try await transport.stream(
                path: "/api/chat",
                method: "POST",
                body: body
            )
        } catch {
            throw mapped(error)
        }

        return LocalAITextStream { continuation in
            let task = Task {
                var sawFinalRecord = false
                do {
                    for try await record in records {
                        try Task.checkCancellation()
                        guard !record.isBlankRecord else { continue }
                        let chunk = try decode(
                            OllamaChatStreamChunk.self,
                            from: record
                        )
                        guard !chunk.hasAPIError else {
                            throw LocalAIError.malformedResponse
                        }
                        if let content = chunk.content {
                            continuation.yield(content)
                        }
                        if chunk.isFinal {
                            sawFinalRecord = true
                            break
                        }
                    }
                    try Task.checkCancellation()
                    guard sawFinalRecord else {
                        throw LocalAIError.malformedResponse
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: mapped(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func unload(model: String) async {
        let unloadRequest = OllamaChatRequest(
            model: model,
            messages: [],
            stream: false,
            keepAlive: .seconds(0)
        )
        guard let body = try? JSONEncoder().encode(unloadRequest) else {
            return
        }
        _ = try? await request(
            path: "/api/chat",
            method: "POST",
            body: body
        )
    }

    private func request(
        path: String,
        method: String,
        body: Data?
    ) async throws -> Data {
        do {
            return try await transport.request(
                path: path,
                method: method,
                body: body
            )
        } catch {
            throw mapped(error)
        }
    }

    /// Keeps every failure bounded: cancellation stays cancellation and
    /// anything else collapses to a fixed local error that carries no server
    /// text.
    private func mapped(_ error: any Error) -> any Error {
        if error is CancellationError {
            return CancellationError()
        }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled:
                return CancellationError()
            case .notConnectedToInternet,
                 .cannotConnectToHost,
                 .networkConnectionLost:
                return LocalAIError.ollamaNotRunning
            case .timedOut:
                return LocalAIError.timedOut
            default:
                return LocalAIError.malformedResponse
            }
        }
        if let error = error as? LocalAIError {
            return error
        }
        return LocalAIError.malformedResponse
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw LocalAIError.malformedResponse
        }
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data
    ) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw LocalAIError.malformedResponse
        }
    }
}

private extension Data {
    /// True when a record carries nothing but newline framing whitespace.
    var isBlankRecord: Bool {
        allSatisfy { byte in
            byte == 0x09 || byte == 0x0A || byte == 0x0B
                || byte == 0x0C || byte == 0x0D || byte == 0x20
        }
    }
}
