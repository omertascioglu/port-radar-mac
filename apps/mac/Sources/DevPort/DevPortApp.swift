// Modification notice: Changed in 2026 for the local AI and optional Ollama fallback contribution, and for the Port Radar Offline fork product identity.
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    typealias CleanupAction = @Sendable () async -> Void
    typealias TerminationReply = @MainActor @Sendable (Bool) async -> Void

    private let closeConversations: CleanupAction
    private let stopPrivateService: CleanupAction
    private let sendTerminationReply: TerminationReply
    private var cleanupTask: Task<Void, Never>?

    override init() {
        closeConversations = {
            await LocalAIConversationRegistry.shared.closeActive()
        }
        stopPrivateService = {
            await OllamaServiceManager.shared.shutdownAll()
        }
        sendTerminationReply = { shouldTerminate in
            NSApplication.shared.reply(
                toApplicationShouldTerminate: shouldTerminate
            )
        }
        super.init()
    }

    #if DEBUG
    init(
        closeConversations: @escaping CleanupAction,
        stopPrivateService: @escaping CleanupAction,
        sendTerminationReply: @escaping TerminationReply
    ) {
        self.closeConversations = closeConversations
        self.stopPrivateService = stopPrivateService
        self.sendTerminationReply = sendTerminationReply
        super.init()
    }
    #endif

    @MainActor
    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        beginOrderedTerminationCleanup()
    }

    /// AppKit's `sender` is never used, so this entry point lets the exit
    /// sequence be driven — and observed — without an `NSApplication` instance.
    /// Exit is deferred rather than blocked: no cleanup step runs on the main
    /// thread, and the reply is delivered only once cleanup has settled.
    @MainActor
    func beginOrderedTerminationCleanup() -> NSApplication.TerminateReply {
        let cleanup = orderedCleanupTask()
        let sendTerminationReply = sendTerminationReply
        Task { @MainActor in
            await cleanup.value
            await sendTerminationReply(true)
        }
        return .terminateLater
    }

    /// Every termination request shares one cleanup task, so each step runs at
    /// most once per launch. Conversations close first — they unload their
    /// models and release their service leases — and the private service
    /// shutdown then runs as the final barrier.
    @MainActor
    private func orderedCleanupTask() -> Task<Void, Never> {
        if let cleanupTask { return cleanupTask }

        let closeConversations = closeConversations
        let stopPrivateService = stopPrivateService
        let task = Task {
            await closeConversations()
            await stopPrivateService()
        }
        cleanupTask = task
        return task
    }
}

@main
struct DevPortApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate

    init() {
        // Touch preferences so defaults are registered before the scanner starts.
        _ = Preferences.shared
        AppState.shared.start()
    }

    var body: some Scene {
        MenuBarExtra("Port Radar Offline", systemImage: "antenna.radiowaves.left.and.right") {
            ContentView()
        }
        .menuBarExtraStyle(.window)
    }
}
