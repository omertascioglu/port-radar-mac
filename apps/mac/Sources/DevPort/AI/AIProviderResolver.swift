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
            if case .available = try await checkedAvailability(
                of: apple,
                modelID: nil
            ) {
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
        switch try await checkedAvailability(of: provider, modelID: modelID) {
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

    private func checkedAvailability(
        of provider: any LocalAIProvider,
        modelID: String?
    ) async throws -> LocalAIAvailability {
        try Task.checkCancellation()
        let availability = await provider.availability(modelID: modelID)
        try Task.checkCancellation()
        return availability
    }

    private func make(
        _ provider: any LocalAIProvider,
        context: SanitizedProcessContext,
        modelID: String?
    ) async throws -> ResolvedLocalAIConversation {
        ResolvedLocalAIConversation(
            conversation: try await provider.makeConversation(
                context: context,
                modelID: modelID
            )
        )
    }
}

extension AIProviderResolver {
    static var live: Self {
        Self(
            apple: AppleFoundationModelProvider(),
            ollama: OllamaProvider()
        )
    }
}
