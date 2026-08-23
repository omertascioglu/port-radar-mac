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

enum LocalAIPrompt {
    static func instructions(context: SanitizedProcessContext) -> String {
        """
        You are a concise assistant inside Port Radar, a macOS menu-bar app that lists localhost listeners.
        The user is asking about one specific process. Use only the process context below.
        If something isn’t in the context, say you don’t know — don’t invent system state.
        Prefer short, practical answers for developers.

        Process context:
        \(context.text)
        """
    }
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
    let conversation: any LocalAIConversation

    var providerID: LocalAIProviderID { conversation.providerID }
    var badgeText: String { providerID.badgeText }
}
