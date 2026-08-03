import SwiftUI

@main
struct DevPortApp: App {
    init() {
        AppState.shared.start()
    }

    var body: some Scene {
        MenuBarExtra("DevPort", systemImage: "antenna.radiowaves.left.and.right") {
            ContentView()
        }
        .menuBarExtraStyle(.window)
    }
}
