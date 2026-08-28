// Modification notice: Added in 2026 for the local AI and optional Ollama fallback contribution, and changed for the Port Radar Offline fork's streamed local responses.
import Foundation

struct OllamaModel: Identifiable, Equatable, Sendable {
    let id: String
    let size: Int64
    let format: String
}

struct OllamaModelDetails: Decodable, Equatable, Sendable {
    let format: String?
}

struct OllamaModelSummary: Decodable, Equatable, Sendable {
    let name: String
    let model: String
    let remoteModel: String?
    let remoteHost: String?
    let size: Int64?
    let digest: String?
    let details: OllamaModelDetails?

    enum CodingKeys: String, CodingKey {
        case name
        case model
        case size
        case digest
        case details
        case remoteModel = "remote_model"
        case remoteHost = "remote_host"
    }

    var isProvenLocal: Bool {
        remoteModel.isNilOrEmpty
            && remoteHost.isNilOrEmpty
            && !name.hasCloudSuffix
            && !model.hasCloudSuffix
            && (size ?? 0) > 0
            && !(digest ?? "").isEmpty
            && !(details?.format ?? "").isEmpty
    }

    var localModel: OllamaModel? {
        guard isProvenLocal else { return nil }

        return OllamaModel(
            id: model.isEmpty ? name : model,
            size: size ?? 0,
            format: details?.format ?? ""
        )
    }
}

struct OllamaTagsResponse: Decodable, Sendable {
    let models: [OllamaModelSummary]

    var validatedLocalModels: [OllamaModel] {
        models.compactMap(\.localModel)
    }
}

struct OllamaShowResponse: Decodable, Equatable, Sendable {
    let remoteModel: String?
    let remoteHost: String?
    let details: OllamaModelDetails?

    enum CodingKeys: String, CodingKey {
        case details
        case remoteModel = "remote_model"
        case remoteHost = "remote_host"
    }

    var confirmsLocalExecution: Bool {
        remoteModel.isNilOrEmpty
            && remoteHost.isNilOrEmpty
            && !(details?.format ?? "").isEmpty
    }
}

struct OllamaVersionResponse: Decodable, Equatable, Sendable {
    let version: String
}

struct OllamaChatMessage: Codable, Equatable, Sendable {
    let role: String
    let content: String
}

struct OllamaChatRequest: Encodable, Equatable, Sendable {
    let model: String
    let messages: [OllamaChatMessage]
    let stream: Bool
    let keepAlive: OllamaKeepAlive

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case keepAlive = "keep_alive"
    }
}

private struct OllamaChatStreamMessage: Decodable, Equatable, Sendable {
    let content: String?
}

/// One newline-delimited record of a streamed `/api/chat` response. The server's
/// `error` text is deliberately reduced to a flag while decoding so no raw
/// server body can reach an error, a log, or the UI.
struct OllamaChatStreamChunk: Decodable, Equatable, Sendable {
    let content: String?
    let isFinal: Bool
    let hasAPIError: Bool

    enum CodingKeys: String, CodingKey {
        case message
        case done
        case error
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let message = try container.decodeIfPresent(
            OllamaChatStreamMessage.self,
            forKey: .message
        )
        let text = message?.content ?? ""
        content = text.isEmpty ? nil : text
        isFinal = try container.decodeIfPresent(Bool.self, forKey: .done)
            ?? false
        hasAPIError = !(
            try container.decodeIfPresent(String.self, forKey: .error) ?? ""
        ).isEmpty
    }
}

struct OllamaAPIErrorResponse: Decodable, Equatable, Sendable {
    let error: String
}

enum OllamaKeepAlive: Encodable, Equatable, Sendable {
    case duration(String)
    case seconds(Int)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .duration(let value):
            try container.encode(value)
        case .seconds(let value):
            try container.encode(value)
        }
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool {
        self?.isEmpty != false
    }
}

private extension String {
    var hasCloudSuffix: Bool {
        let normalized = trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasSuffix(":cloud") || normalized.hasSuffix("-cloud")
    }
}
