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
                return AppleFoundationModelConversation(context: context)
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
private actor AppleFoundationModelConversation: LocalAIConversation {
    nonisolated let providerID: LocalAIProviderID = .apple
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
