import SwiftUI

@main
struct DevPortApp: App {
    init() {
        // Touch preferences so defaults are registered before the scanner starts.
        _ = Preferences.shared
        AppState.shared.start()
    }

    var body: some Scene {
        MenuBarExtra("DevPort", systemImage: "antenna.radiowaves.left.and.right") {
            ContentView()
        }
        .menuBarExtraStyle(.window)
    }
}
