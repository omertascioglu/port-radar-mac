// Modification notice: Added in 2026 for the local AI and optional Ollama fallback contribution, and changed for the Port Radar Offline fork's ordered exit cleanup.
import Foundation

actor LocalAIConversationRegistry {
    static let shared = LocalAIConversationRegistry()

    private var active:
        (token: UUID, conversation: ManagedLocalAIConversation)?
    // closeActive is the one-way app-termination barrier: late resolutions
    // are closed instead of becoming newly owned while the app is exiting.
    // App exit runs it before the private service shutdown, so conversations
    // unload their models and release their leases first.
    private var isTerminating = false
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    @discardableResult
    func register(
        token: UUID,
        conversation: any LocalAIConversation
    ) async -> (any LocalAIConversation)? {
        let managed = ManagedLocalAIConversation(conversation)
        await acquireOperation()
        defer { releaseOperation() }

        guard !isTerminating else {
            await managed.close()
            return nil
        }

        if let previous = active {
            await previous.conversation.close()
        }
        active = (token, managed)
        return managed
    }

    func unregister(token: UUID) async {
        await acquireOperation()
        defer { releaseOperation() }

        guard active?.token == token else { return }
        active = nil
    }

    func closeActive() async {
        await acquireOperation()
        defer { releaseOperation() }

        isTerminating = true
        let current = active
        active = nil
        await current?.conversation.close()
    }

#if DEBUG
    func hasActiveConversationForTesting() -> Bool {
        active != nil
    }
#endif

    private func acquireOperation() async {
        guard operationInProgress else {
            operationInProgress = true
            return
        }

        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperation() {
        guard !operationWaiters.isEmpty else {
            operationInProgress = false
            return
        }
        operationWaiters.removeFirst().resume()
    }
}

/// Shares one idempotent provider-close operation between the modal and the
/// termination hook, even if both cleanup paths race.
private actor ManagedLocalAIConversation: LocalAIConversation {
    nonisolated let providerID: LocalAIProviderID

    private let conversation: any LocalAIConversation
    private var closeTask: Task<Void, Never>?
    private var didClose = false

    init(_ conversation: any LocalAIConversation) {
        self.providerID = conversation.providerID
        self.conversation = conversation
    }

    func streamResponse(to prompt: String) async throws -> LocalAITextStream {
        guard !didClose else { throw CancellationError() }
        return try await conversation.streamResponse(to: prompt)
    }

    func close() async {
        if didClose { return }
        if let closeTask {
            await closeTask.value
            return
        }

        let conversation = conversation
        let task = Task {
            await conversation.close()
        }
        closeTask = task
        await task.value
        didClose = true
        closeTask = nil
    }
}
