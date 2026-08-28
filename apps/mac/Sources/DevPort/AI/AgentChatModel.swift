import Foundation
import Observation

struct AgentMessage: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
        case system
    }

    let id: UUID
    let role: Role
    var text: String

    /// A caller-supplied ID lets streamed chunks mutate one assistant message
    /// instead of appending a bubble per chunk.
    init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
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
    /// Bumped by every streamed change, so the chat can follow a reply that
    /// grows inside one message instead of only reacting to new messages.
    private(set) var streamRevision = 0

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
        let placeholder = AgentMessage(role: .assistant, text: "")
        messages.append(.init(role: .user, text: prompt))
        messages.append(placeholder)
        isSending = true
        streamRevision &+= 1
        generationAttempt &+= 1
        let attempt = generationAttempt
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performGeneration(
                prompt: prompt,
                conversation: conversation,
                attempt: attempt,
                messageID: placeholder.id
            )
        }
        generationTask = task
    }

    /// Cancels the streaming turn without closing the conversation, so the
    /// received partial text stays on screen and the next question still works.
    func stopGeneration() {
        generationTask?.cancel()
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

    /// Renders chunks into the placeholder as they arrive. A cancelled consumer
    /// is handed `nil` by the stream rather than an error, so cancellation is
    /// checked explicitly: a stopped turn keeps what it already showed and a
    /// buffered chunk can never land after the stop.
    private func performGeneration(
        prompt: String,
        conversation: any LocalAIConversation,
        attempt: Int,
        messageID: UUID
    ) async {
        do {
            let stream = try await conversation.streamResponse(to: prompt)
            try Task.checkCancellation()
            for try await chunk in stream {
                try Task.checkCancellation()
                guard applyChunk(chunk, attempt: attempt, messageID: messageID)
                else { break }
            }
            try Task.checkCancellation()
        } catch {
            guard !isClosed,
                  generationAttempt == attempt,
                  !Task.isCancelled,
                  !Self.isCancellation(error)
            else {
                finishGeneration(attempt: attempt, messageID: messageID)
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
        finishGeneration(attempt: attempt, messageID: messageID)
    }

    /// Appends to the streaming placeholder only while the attempt, the message
    /// and the open state all still match, so a superseded or closed turn can
    /// never revive cleared state.
    private func applyChunk(
        _ chunk: String,
        attempt: Int,
        messageID: UUID
    ) -> Bool {
        guard !isClosed,
              generationAttempt == attempt,
              let index = messages.firstIndex(where: { $0.id == messageID })
        else { return false }

        messages[index].text += chunk
        streamRevision &+= 1
        return true
    }

    private func finishGeneration(attempt: Int, messageID: UUID) {
        guard !isClosed, generationAttempt == attempt else { return }
        discardEmptyPlaceholder(messageID)
        generationTask = nil
        isSending = false
    }

    /// A turn that ended before its first chunk leaves no empty bubble behind.
    private func discardEmptyPlaceholder(_ messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              messages[index].text.isEmpty
        else { return }

        messages.remove(at: index)
        streamRevision &+= 1
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
