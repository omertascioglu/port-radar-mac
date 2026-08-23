struct AIProviderResolver: Sendable {
    let apple: any LocalAIProvider
    let ollama: any LocalAIProvider

    func resolve(
        preference: LocalAIProviderPreference,
        ollamaModelID: String?,
        context: SanitizedProcessContext
    ) async throws -> ResolvedLocalAIConversation {
        switch preference {
        case .automatic:
            if case .available = await apple.availability(modelID: nil) {
                return try await make(apple, context: context, modelID: nil)
            }
            return try await require(
                ollama,
                context: context,
                modelID: ollamaModelID
            )
        case .apple:
            return try await require(apple, context: context, modelID: nil)
        case .ollama:
            return try await require(
                ollama,
                context: context,
                modelID: ollamaModelID
            )
        }
    }

    private func require(
        _ provider: any LocalAIProvider,
        context: SanitizedProcessContext,
        modelID: String?
    ) async throws -> ResolvedLocalAIConversation {
        switch await provider.availability(modelID: modelID) {
        case .available:
            return try await make(
                provider,
                context: context,
                modelID: modelID
            )
        case .unavailable(let error):
            throw error
        }
    }

    private func make(
        _ provider: any LocalAIProvider,
        context: SanitizedProcessContext,
        modelID: String?
    ) async throws -> ResolvedLocalAIConversation {
        ResolvedLocalAIConversation(
            providerID: provider.id,
            conversation: try await provider.makeConversation(
                context: context,
                modelID: modelID
            )
        )
    }
}
