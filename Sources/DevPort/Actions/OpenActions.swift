import AppKit
import Foundation

@MainActor
enum OpenActions {

    static func openInBrowser(_ server: DevServer) {
        NSWorkspace.shared.open(server.url)
    }

    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func openInEditor(_ path: String) {
        let bundleID = Preferences.shared.preferredIDEBundleID
        let folder = URL(fileURLWithPath: path)

        if !bundleID.isEmpty,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.open(
                [folder],
                withApplicationAt: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
            return
        }

        // Fall back to macOS default app for folders / first detected editor.
        if let fallback = IDEDetector.preferredDefault(),
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: fallback.bundleIdentifier) {
            NSWorkspace.shared.open(
                [folder],
                withApplicationAt: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
            return
        }

        NSWorkspace.shared.open(folder)
    }

    static func openInTerminal(_ path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", path]
        try? process.run()
    }
}
