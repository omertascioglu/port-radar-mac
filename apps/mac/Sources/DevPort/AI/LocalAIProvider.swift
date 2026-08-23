import Foundation

enum LocalAIProviderID: String, Equatable, Sendable {
    case apple
    case ollama

    var badgeText: String {
        switch self {
        case .apple: "Apple · On-device"
        case .ollama: "Ollama · Local"
        }
    }
}

enum LocalAIProviderPreference: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case apple
    case ollama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .apple: "Apple Intelligence"
        case .ollama: "Ollama"
        }
    }

    static func persistedValue(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .automatic
    }
}

struct SanitizedProcessContext: Equatable, Sendable {
    let text: String
}

enum LocalAIAvailability: Equatable, Sendable {
    case available
    case unavailable(LocalAIError)
}

protocol LocalAIConversation: Sendable {
    var providerID: LocalAIProviderID { get }
    func respond(to prompt: String) async throws -> String
    func close() async
}

protocol LocalAIProvider: Sendable {
    var id: LocalAIProviderID { get }
    func availability(modelID: String?) async -> LocalAIAvailability
    func makeConversation(
        context: SanitizedProcessContext,
        modelID: String?
    ) async throws -> any LocalAIConversation
}

struct ResolvedLocalAIConversation: Sendable {
    let providerID: LocalAIProviderID
    let conversation: any LocalAIConversation

    var badgeText: String { providerID.badgeText }
}
