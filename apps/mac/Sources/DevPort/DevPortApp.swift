// Modification notice: Changed in 2026 for the local AI and optional Ollama fallback contribution, and for the Port Radar Offline fork product identity.
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let cleanup: @Sendable () async -> Void

    override init() {
        self.cleanup = {
            await LocalAIConversationRegistry.shared.closeActive()
        }
        super.init()
    }

    init(cleanup: @escaping @Sendable () async -> Void) {
        self.cleanup = cleanup
        super.init()
    }

    func applicationWillTerminate(_ notification: Notification) {
        let cleanup = cleanup
        Task {
            await cleanup()
        }
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
