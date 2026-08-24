// Modification notice: Added in 2026 for the Port Radar Offline fork.
import Foundation
import XCTest

final class OfflineProductBoundaryTests: XCTestCase {
    func testShippingSourcesContainNoPublicSharingImplementation() throws {
        let sourceRoot = try sourceRootURL()
        let forbidden = [
            ["Cloud", "flared"].joined(),
            ["Tunn", "elManager"].joined(),
            ["Tunn", "elsModal"].joined(),
            ["trycloud", "flare.com"].joined(),
            ["Share via ", "Cloud", "flare"].joined(),
        ]
        let broadlyForbidden = [
            ["cloud", "flare"].joined(),
            ["tunn", "el"].joined(),
        ]
        let violations = try swiftSources(at: sourceRoot).flatMap { url in
            let text = try String(contentsOf: url, encoding: .utf8)
            let relativePath = url.path.replacingOccurrences(of: sourceRoot.path + "/", with: "")
            let exactViolations = forbidden.compactMap { token in
                text.contains(token) ? "\(relativePath): \(token)" : nil
            }
            let caseFoldedText = text.lowercased()
            let broadViolations = broadlyForbidden.compactMap { token in
                caseFoldedText.contains(token) ? "\(relativePath): \(token)" : nil
            }
            return exactViolations + broadViolations
        }
        XCTAssertEqual(violations, [])
    }

    func testShippingSwiftSourcesContainNoLegacyProductIdentity() throws {
        let sourceRoot = try sourceRootURL()
        let violations = try swiftSources(at: sourceRoot).flatMap { url in
            let text = try String(contentsOf: url, encoding: .utf8)
            let relativePath = url.path.replacingOccurrences(of: sourceRoot.path + "/", with: "")
            let withoutOfflineName = text.replacingOccurrences(of: "Port Radar Offline", with: "")
            var fileViolations: [String] = []

            if withoutOfflineName.contains("Port Radar") {
                fileViolations.append("\(relativePath): legacy Port Radar name")
            }
            if text.contains("com.sebsol.DevPort") {
                fileViolations.append("\(relativePath): legacy com.sebsol.DevPort identifier")
            }

            return fileViolations
        }

        XCTAssertEqual(violations, [])
    }

    func testChangedShippingSourcesCarryOfflineModificationNotice() throws {
        let sourceRoot = try sourceRootURL()
        let notices = [
            "Actions/LaunchAtLogin.swift": "// Modification notice: Changed in 2026 for the Port Radar Offline fork product identity.",
            "AI/LocalAIError.swift": "// Modification notice: Changed in 2026 for the local AI and optional Ollama fallback contribution, and for the Port Radar Offline fork product identity.",
            "AI/LocalAIProvider.swift": "// Modification notice: Changed in 2026 for the local AI and optional Ollama fallback contribution, and for the Port Radar Offline fork product identity.",
            "DevPortApp.swift": "// Modification notice: Changed in 2026 for the local AI and optional Ollama fallback contribution, and for the Port Radar Offline fork product identity.",
            "Scanner/PortScanner.swift": "// Modification notice: Changed in 2026 for the Port Radar Offline fork product identity.",
            "State/AppState.swift": "// Modification notice: Changed in 2026 for the Port Radar Offline fork to remove public sharing.",
            "State/Preferences.swift": "// Modification notice: Changed in 2026 for the local AI and optional Ollama fallback contribution, and for the Port Radar Offline fork product identity.",
            "Views/ContentView.swift": "// Modification notice: Changed in 2026 for the local AI and optional Ollama fallback contribution, and for the Port Radar Offline fork to remove public sharing and adopt its product identity.",
        ]

        for (relativePath, notice) in notices {
            let url = sourceRoot.appendingPathComponent(relativePath)
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(text.hasPrefix(notice), "\(relativePath) must start with the fork modification notice")
        }
    }

    func testBundleIdentityUsesOfflineProductName() throws {
        let plistURL = try packageRootURL()
            .appendingPathComponent("Support/Info.plist")
        let data = try Data(contentsOf: plistURL)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any] else {
            throw SourceDiscoveryError.cannotDecodePropertyList(plistURL.path)
        }

        XCTAssertEqual(plist["CFBundleName"] as? String, "Port Radar Offline")
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "Port Radar Offline")
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.omertascioglu.PortRadarOffline")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "DevPort")
    }

    func testMakefileUsesOfflineBundleAndDiskImageNames() throws {
        let makefileURL = try packageRootURL().appendingPathComponent("Makefile")
        let text = try String(contentsOf: makefileURL, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        XCTAssertTrue(lines.contains("PRODUCT_NAME := Port Radar Offline"))
        XCTAssertTrue(lines.contains("DMG          := $(DIST)/Port-Radar-Offline-$(VERSION).dmg"))
        XCTAssertTrue(lines.contains("DMG_LATEST   := $(DIST)/Port-Radar-Offline.dmg"))
        XCTAssertTrue(lines.contains("EXECUTABLE   := DevPort"))
    }

    func testVisibleShippingStringsIdentifyPortRadarOffline() throws {
        let sourceRoot = try sourceRootURL()
        let appText = try String(
            contentsOf: sourceRoot.appendingPathComponent("DevPortApp.swift"),
            encoding: .utf8
        )
        let contentText = try String(
            contentsOf: sourceRoot.appendingPathComponent("Views/ContentView.swift"),
            encoding: .utf8
        )
        let providerText = try String(
            contentsOf: sourceRoot.appendingPathComponent("AI/LocalAIProvider.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(appText.contains("MenuBarExtra(\"Port Radar Offline\""))
        XCTAssertTrue(contentText.contains("Text(\"Port Radar Offline\")"))
        XCTAssertTrue(contentText.contains("Text(\"Quit Port Radar Offline\")"))
        XCTAssertTrue(contentText.contains("Text(\"Quit Port Radar Offline?\")"))
        XCTAssertTrue(providerText.contains("assistant inside Port Radar Offline,"))
    }

    func testServerRowDisablesMenuWithoutAskOrFolderActions() throws {
        let sourceRoot = try sourceRootURL()
        let contentView = sourceRoot.appendingPathComponent("Views/ContentView.swift")
        let text = try String(contentsOf: contentView, encoding: .utf8)
        let expected = [
            "private var hasMenu",
            "Actions: Bool { showAsk || folderPath != nil }",
        ].joined()

        XCTAssertTrue(text.contains(expected))
    }

    private func sourceRootURL() throws -> URL {
        let packageRoot = try packageRootURL()
        let sourceRoot = packageRoot.appendingPathComponent("Sources/DevPort", isDirectory: true)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SourceDiscoveryError.missingSourceRoot(sourceRoot.path)
        }

        return sourceRoot
    }

    private func packageRootURL() throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: packageRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SourceDiscoveryError.missingPackageRoot(packageRoot.path)
        }

        return packageRoot
    }

    private func swiftSources(at sourceRoot: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw SourceDiscoveryError.cannotEnumerateSourceRoot(sourceRoot.path)
        }

        return try enumerator.compactMap { item in
            guard let url = item as? URL,
                  url.pathExtension == "swift",
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                return nil
            }
            return url
        }
        .sorted { $0.path < $1.path }
    }
}

private enum SourceDiscoveryError: Error {
    case missingPackageRoot(String)
    case missingSourceRoot(String)
    case cannotEnumerateSourceRoot(String)
    case cannotDecodePropertyList(String)
}
