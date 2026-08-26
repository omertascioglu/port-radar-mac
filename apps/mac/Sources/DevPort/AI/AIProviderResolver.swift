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
            return try await make(
                ollama,
                context: context,
                modelID: ollamaModelID
            )
        case .apple:
            return try await require(apple, context: context, modelID: nil)
        case .ollama:
            return try await make(
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

    /// Creates one conversation. Ollama owns a private service of its own, so
    /// creation *is* its availability check: a separate probe would start and
    /// stop the child service before the real acquire, and the conversation's
    /// own error already says why it could not start.
    private func make(
        _ provider: any LocalAIProvider,
        context: SanitizedProcessContext,
        modelID: String?
    ) async throws -> ResolvedLocalAIConversation {
        try Task.checkCancellation()
        let conversation = try await provider.makeConversation(
            context: context,
            modelID: modelID
        )
        guard !Task.isCancelled else {
            // A created conversation may already own the private service, so a
            // late cancellation closes it instead of dropping it.
            await conversation.close()
            throw CancellationError()
        }
        return ResolvedLocalAIConversation(conversation: conversation)
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
