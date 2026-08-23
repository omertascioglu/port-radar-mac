import Foundation
import Observation

struct AgentMessage: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
        case system
    }

    let id = UUID()
    let role: Role
    var text: String
}

@MainActor
@Observable
final class AgentChatModel {
    let server: DevServer

    private let resolver: AIProviderResolver
    private let preference: LocalAIProviderPreference
    private let ollamaModelID: String
    private let conversationRegistry: LocalAIConversationRegistry
    private let conversationToken = UUID()
    private let contextBuilder:
        @MainActor @Sendable (DevServer) -> SanitizedProcessContext

    var draft = ""
    private(set) var messages: [AgentMessage] = []
    private(set) var isSending = false
    private(set) var availabilityNote: String?
    private(set) var badgeText: String?

    private var conversation: (any LocalAIConversation)?
    private var bootstrapTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var bootstrapAttempt = 0
    private var generationAttempt = 0
    private var isClosed = false

    init(
        server: DevServer,
        resolver: AIProviderResolver,
        preference: LocalAIProviderPreference,
        ollamaModelID: String,
        conversationRegistry: LocalAIConversationRegistry = .shared,
        contextBuilder: @escaping @MainActor @Sendable (DevServer) ->
            SanitizedProcessContext = { $0.sanitizedAgentContext }
    ) {
        self.server = server
        self.resolver = resolver
        self.preference = preference
        self.ollamaModelID = ollamaModelID
        self.conversationRegistry = conversationRegistry
        self.contextBuilder = contextBuilder
    }

    var canSend: Bool {
        !isClosed
            && conversation != nil
            && generationTask == nil
            && availabilityNote == nil
            && !draft.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
    }

    func bootstrap() async {
        guard !isClosed, conversation == nil else { return }
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }

        availabilityNote = nil
        badgeText = nil
        bootstrapAttempt &+= 1
        let attempt = bootstrapAttempt
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performBootstrap(attempt: attempt)
        }
        bootstrapTask = task
        await task.value
        if bootstrapAttempt == attempt {
            bootstrapTask = nil
        }
    }

    func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, let conversation, !prompt.isEmpty else { return }

        draft = ""
        messages.append(.init(role: .user, text: prompt))
        isSending = true
        generationAttempt &+= 1
        let attempt = generationAttempt
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performGeneration(
                prompt: prompt,
                conversation: conversation,
                attempt: attempt
            )
        }
        generationTask = task
    }

    /// Starts idempotent cleanup without requiring an untracked view task.
    func beginClose() {
        guard closeTask == nil else { return }

        isClosed = true
        bootstrapTask?.cancel()
        generationTask?.cancel()

        let bootstrap = bootstrapTask
        let generation = generationTask
        let activeConversation = conversation

        conversation = nil
        generationTask = nil
        draft = ""
        messages.removeAll()
        isSending = false
        availabilityNote = nil
        badgeText = nil

        closeTask = Task {
            await activeConversation?.close()
            if let generation {
                await generation.value
            }
            if let bootstrap {
                await bootstrap.value
            }
            await conversationRegistry.unregister(token: conversationToken)
        }
    }

    func close() async {
        beginClose()
        await closeTask?.value
    }

    private func performBootstrap(attempt: Int) async {
        let context = contextBuilder(server)

        do {
            let resolved = try await resolver.resolve(
                preference: preference,
                ollamaModelID: ollamaModelID.isEmpty ? nil : ollamaModelID,
                context: context
            )
            guard !isClosed,
                  !Task.isCancelled,
                  bootstrapAttempt == attempt
            else {
                await resolved.conversation.close()
                return
            }

            guard let registeredConversation = await conversationRegistry
                .register(
                    token: conversationToken,
                    conversation: resolved.conversation
                )
            else { return }

            guard !isClosed,
                  !Task.isCancelled,
                  bootstrapAttempt == attempt
            else {
                await registeredConversation.close()
                await conversationRegistry.unregister(
                    token: conversationToken
                )
                return
            }

            conversation = registeredConversation
            badgeText = resolved.badgeText
            messages = [
                .init(
                    role: .system,
                    text: resolved.providerID == .apple
                        ? "Apple's on-device model has sanitized process context."
                        : "Your local Ollama model has sanitized process context."
                ),
            ]
        } catch {
            guard !isClosed,
                  !Task.isCancelled,
                  bootstrapAttempt == attempt,
                  !Self.isCancellation(error)
            else { return }
            availabilityNote = Self.boundedMessage(
                for: error,
                fallback: "Local AI is unavailable."
            )
        }
    }

    private func performGeneration(
        prompt: String,
        conversation: any LocalAIConversation,
        attempt: Int
    ) async {
        do {
            let response = try await conversation.respond(to: prompt)
            try Task.checkCancellation()
            guard !isClosed, generationAttempt == attempt else { return }
            messages.append(.init(role: .assistant, text: response))
        } catch {
            guard !isClosed,
                  generationAttempt == attempt,
                  !Task.isCancelled,
                  !Self.isCancellation(error)
            else {
                finishGeneration(attempt: attempt)
                return
            }
            messages.append(.init(
                role: .system,
                text: Self.boundedMessage(
                    for: error,
                    fallback: "The local model could not complete the request."
                )
            ))
        }
        finishGeneration(attempt: attempt)
    }

    private func finishGeneration(attempt: Int) {
        guard !isClosed, generationAttempt == attempt else { return }
        generationTask = nil
        isSending = false
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError
    }

    private static func boundedMessage(
        for error: any Error,
        fallback: String
    ) -> String {
        guard let localError = error as? LocalAIError,
              let description = localError.errorDescription
        else { return fallback }

        let singleLine = description
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
        return String(singleLine.prefix(240))
    }
}
