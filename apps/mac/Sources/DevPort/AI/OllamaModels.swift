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

struct OllamaChatResponse: Decodable, Equatable, Sendable {
    let message: OllamaChatMessage
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
