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

    func testChangedShippingSourcesCarryOfflineModificationNotice() throws {
        let sourceRoot = try sourceRootURL()
        let notices = [
            "State/AppState.swift": "// Modification notice: Changed in 2026 for the Port Radar Offline fork to remove public sharing.",
            "Views/ContentView.swift": "// Modification notice: Changed in 2026 for the local AI and optional Ollama fallback contribution, and for the Port Radar Offline fork to remove public sharing.",
        ]

        for (relativePath, notice) in notices {
            let url = sourceRoot.appendingPathComponent(relativePath)
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(text.hasPrefix(notice), "\(relativePath) must start with the fork modification notice")
        }
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
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = packageRoot.appendingPathComponent("Sources/DevPort", isDirectory: true)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SourceDiscoveryError.missingSourceRoot(sourceRoot.path)
        }

        return sourceRoot
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
    case missingSourceRoot(String)
    case cannotEnumerateSourceRoot(String)
}
