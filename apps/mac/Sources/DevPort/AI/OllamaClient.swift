// Modification notice: Changed in 2026 for the Port Radar Offline fork's private local Ollama service.
import Foundation

protocol OllamaClientProtocol: Sendable {
    func version() async throws -> String
    func localModels() async throws -> [OllamaModel]
    func validateLocalModel(_ id: String) async throws
    func chat(
        model: String,
        messages: [OllamaChatMessage]
    ) async throws -> String
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

    /// Lease lifetime stays with the callers that own a conversation or a
    /// settings refresh; this only guarantees the private-service binding.
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

    func chat(
        model: String,
        messages: [OllamaChatMessage]
    ) async throws -> String {
        let chatRequest = OllamaChatRequest(
            model: model,
            messages: messages,
            stream: false,
            keepAlive: .duration("2m")
        )
        let data = try await request(
            path: "/api/chat",
            method: "POST",
            body: try encode(chatRequest)
        )
        return try decode(OllamaChatResponse.self, from: data)
            .message.content
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
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            switch error.code {
            case .cancelled:
                throw CancellationError()
            case .notConnectedToInternet,
                 .cannotConnectToHost,
                 .networkConnectionLost:
                throw LocalAIError.ollamaNotRunning
            case .timedOut:
                throw LocalAIError.timedOut
            default:
                throw LocalAIError.malformedResponse
            }
        } catch let error as LocalAIError {
            throw error
        } catch is OllamaHTTPError {
            throw LocalAIError.malformedResponse
        } catch {
            throw LocalAIError.malformedResponse
        }
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
