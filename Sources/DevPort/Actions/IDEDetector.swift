import AppKit
import Foundation

struct EditorApp: Identifiable, Hashable, Sendable {
    let name: String
    let bundleIdentifier: String
    var id: String { bundleIdentifier }
}

enum IDEDetector {
    /// Common macOS editors we know how to open a folder in.
    static let catalog: [EditorApp] = [
        EditorApp(name: "Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92"),
        EditorApp(name: "Visual Studio Code", bundleIdentifier: "com.microsoft.VSCode"),
        EditorApp(name: "VS Code Insiders", bundleIdentifier: "com.microsoft.VSCodeInsiders"),
        EditorApp(name: "Zed", bundleIdentifier: "dev.zed.Zed"),
        EditorApp(name: "Windsurf", bundleIdentifier: "com.exafunction.windsurf"),
        EditorApp(name: "Sublime Text", bundleIdentifier: "com.sublimetext.4"),
        EditorApp(name: "Sublime Text 3", bundleIdentifier: "com.sublimetext.3"),
        EditorApp(name: "Nova", bundleIdentifier: "com.panic.Nova"),
        EditorApp(name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode"),
        EditorApp(name: "IntelliJ IDEA", bundleIdentifier: "com.jetbrains.intellij"),
        EditorApp(name: "IntelliJ IDEA CE", bundleIdentifier: "com.jetbrains.intellij.ce"),
        EditorApp(name: "WebStorm", bundleIdentifier: "com.jetbrains.WebStorm"),
        EditorApp(name: "PyCharm", bundleIdentifier: "com.jetbrains.pycharm"),
        EditorApp(name: "PyCharm CE", bundleIdentifier: "com.jetbrains.pycharm.ce"),
        EditorApp(name: "GoLand", bundleIdentifier: "com.jetbrains.goland"),
        EditorApp(name: "PhpStorm", bundleIdentifier: "com.jetbrains.PhpStorm"),
        EditorApp(name: "RustRover", bundleIdentifier: "com.jetbrains.rustrover"),
        EditorApp(name: "CLion", bundleIdentifier: "com.jetbrains.CLion"),
        EditorApp(name: "Fleet", bundleIdentifier: "com.jetbrains.fleet"),
        EditorApp(name: "TextEdit", bundleIdentifier: "com.apple.TextEdit"),
    ]

    /// Editors currently installed (resolved via Launch Services).
    static func installed() -> [EditorApp] {
        catalog.filter { isInstalled($0.bundleIdentifier) }
    }

    static func isInstalled(_ bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    static func displayName(for bundleIdentifier: String) -> String? {
        catalog.first { $0.bundleIdentifier == bundleIdentifier }?.name
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
                .map { $0.deletingPathExtension().lastPathComponent }
    }

    /// Prefer Cursor → VS Code → Zed → first installed.
    static func preferredDefault() -> EditorApp? {
        let installed = installed()
        let preferredOrder = [
            "com.todesktop.230313mzl4w4u92",
            "com.microsoft.VSCode",
            "dev.zed.Zed",
            "com.apple.dt.Xcode",
        ]
        for id in preferredOrder {
            if let match = installed.first(where: { $0.bundleIdentifier == id }) {
                return match
            }
        }
        return installed.first
    }
}
