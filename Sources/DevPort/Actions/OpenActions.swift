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

    static func openInCursor(_ path: String) {
        let cursorBundleID = "com.todesktop.230313mzl4w4u92"
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: cursorBundleID) {
            NSWorkspace.shared.open(
                [URL(fileURLWithPath: path)],
                withApplicationAt: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
        } else {
            // Fall back to the `open -a` lookup by name.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "Cursor", path]
            try? process.run()
        }
    }

    static func openInTerminal(_ path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", path]
        try? process.run()
    }

    static func copyCommand(_ server: DevServer) {
        guard let command = server.command else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
}
