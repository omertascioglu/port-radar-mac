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
            if text.contains(["com.sebsol.", "DevPort"].joined()) {
                fileViolations.append("\(relativePath): legacy upstream bundle identifier")
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
            "AI/OllamaClient.swift": "// Modification notice: Changed in 2026 for the Port Radar Offline fork's private local Ollama service.",
            "AI/OllamaProcess.swift": "// Modification notice: Added in 2026 for the Port Radar Offline fork.",
            "AI/OllamaProvider.swift": "// Modification notice: Changed in 2026 for the Port Radar Offline fork's private local Ollama service.",
            "AI/OllamaSettingsModel.swift": "// Modification notice: Changed in 2026 for the Port Radar Offline fork's private local Ollama service.",
            "AI/OllamaTransport.swift": "// Modification notice: Changed in 2026 for the Port Radar Offline fork's private local Ollama service.",
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

    // MARK: - Repository copy audit

    func testPublicCopyAdvertisesNoPublicSharingOrUpstreamProduct() throws {
        let repositoryRoot = try repositoryRootURL()
        let caseFoldedForbidden = [
            ["cloud", "flare"].joined(),
            ["tunn", "el"].joined(),
            ["product", "hunt"].joined(),
            ["product ", "hunt"].joined(),
            ["public ", "url"].joined(),
            ["public ", "link"].joined(),
            ["stop ", "sharing"].joined(),
            ["one-click ", "share"].joined(),
            ["one-button ", "share"].joined(),
            ["portradar", ".app"].joined(),
        ]
        let exactForbidden = [
            ["Port-Radar", ".dmg"].joined(),
            ["Port Radar", ".app"].joined(),
            ["com.sebsol.", "DevPort"].joined(),
            ["juansebsol/port-radar-mac", "/releases"].joined(),
        ]

        let violations = try auditableFiles(at: repositoryRoot).flatMap { url in
            let relativePath = Self.relativePath(of: url, in: repositoryRoot)
            let scannable = Self.scannableCopy(
                in: try String(contentsOf: url, encoding: .utf8),
                relativePath: relativePath
            )
            let caseFolded = scannable.lowercased()

            return caseFoldedForbidden.compactMap {
                caseFolded.contains($0) ? "\(relativePath): \($0)" : nil
            } + exactForbidden.compactMap {
                scannable.contains($0) ? "\(relativePath): \($0)" : nil
            }
        }

        XCTAssertEqual(violations, [])
    }

    func testReadmePresentsTheOfflineFork() throws {
        let readme = try String(
            contentsOf: try repositoryRootURL().appendingPathComponent("README.md"),
            encoding: .utf8
        )

        XCTAssertTrue(readme.contains("Port Radar Offline"))
        XCTAssertTrue(
            readme.contains("A tunnel-free, offline-focused fork of Port Radar")
        )
        XCTAssertTrue(readme.contains("https://github.com/juansebsol/port-radar-mac"))
        XCTAssertTrue(
            readme.contains(
                "https://github.com/omertascioglu/port-radar-mac/releases/latest/download/Port-Radar-Offline.dmg"
            )
        )
    }

    func testNoticeKeepsUpstreamAttributionAndAddsForkAttribution() throws {
        let notice = try String(
            contentsOf: try repositoryRootURL().appendingPathComponent("NOTICE"),
            encoding: .utf8
        )

        XCTAssertTrue(
            notice.contains(Self.upstreamNotice),
            "NOTICE must retain the complete upstream notice verbatim"
        )
        XCTAssertTrue(notice.contains("Port Radar Offline modifications"))
        XCTAssertTrue(notice.contains("Ömer Taşçıoğlu"))
    }

    func testWebMarketingUsesTheOfflineIdentityAndForkURLs() throws {
        let repositoryRoot = try repositoryRootURL()
        let webRoot = repositoryRoot.appendingPathComponent("apps/web", isDirectory: true)
        let marketingFiles = try auditableFiles(
            at: webRoot.appendingPathComponent("src", isDirectory: true)
        ) + [webRoot.appendingPathComponent("README.md")]

        let violations = try marketingFiles.compactMap { url -> String? in
            let text = try String(contentsOf: url, encoding: .utf8)
            let withoutOfflineName = text.replacingOccurrences(
                of: "Port Radar Offline",
                with: ""
            )
            guard withoutOfflineName.contains("Port Radar") else { return nil }
            return "\(Self.relativePath(of: url, in: repositoryRoot)): legacy Port Radar name"
        }
        XCTAssertEqual(violations, [])

        let siteConfig = try String(
            contentsOf: webRoot.appendingPathComponent("src/lib/site.ts"),
            encoding: .utf8
        )
        XCTAssertTrue(
            siteConfig.contains("https://github.com/omertascioglu/port-radar-mac")
        )
        XCTAssertTrue(
            siteConfig.contains(
                "https://github.com/omertascioglu/port-radar-mac/releases/latest/download/Port-Radar-Offline.dmg"
            )
        )
    }

    func testWebDemoShowsAnOfflineStreamingAskState() throws {
        let webRoot = try repositoryRootURL()
            .appendingPathComponent("apps/web", isDirectory: true)
        let demo = try String(
            contentsOf: webRoot.appendingPathComponent("src/components/AppDemo.tsx"),
            encoding: .utf8
        )
        let press = try String(
            contentsOf: webRoot.appendingPathComponent("src/components/PressPanel.tsx"),
            encoding: .utf8
        )

        XCTAssertTrue(demo.contains("ask-stream"))
        XCTAssertTrue(demo.contains("Stop response"))
        XCTAssertTrue(demo.contains("Offline — data never leaves this Mac."))
        XCTAssertTrue(press.contains("\"stream\""))
    }

    func testChangedPublicDocumentsCarryOfflineModificationNotice() throws {
        let repositoryRoot = try repositoryRootURL()
        let contributionAndFork =
            "Changed in 2026 for the local AI and optional Ollama fallback "
            + "contribution, and for the Port Radar Offline fork."
        let fork = "Changed in 2026 for the Port Radar Offline fork."
        let notices = [
            "README.md": "<!-- Modification notice: \(contributionAndFork) -->",
            "apps/mac/README.md": "<!-- Modification notice: \(contributionAndFork) -->",
            "apps/web/README.md": "<!-- Modification notice: \(fork) -->",
            "apps/web/src/app/globals.css": "/* Modification notice: \(fork) */",
            "apps/web/src/app/layout.tsx": "// Modification notice: \(fork)",
            "apps/web/src/app/page.tsx": "// Modification notice: \(fork)",
            "apps/web/src/app/press/gallery/[slide]/page.tsx":
                "// Modification notice: \(fork)",
            "apps/web/src/components/AppDemo.tsx": "// Modification notice: \(fork)",
            "apps/web/src/components/PressPanel.tsx": "// Modification notice: \(fork)",
            "apps/web/src/lib/site.ts": "// Modification notice: \(fork)",
        ]

        for (relativePath, notice) in notices {
            let text = try String(
                contentsOf: repositoryRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            XCTAssertTrue(
                text.hasPrefix(notice),
                "\(relativePath) must start with the fork modification notice"
            )
        }
    }

    // MARK: - Audit helpers

    /// The upstream notice Apache 2.0 requires this fork to keep verbatim. It
    /// is exempt from the forbidden-copy scan for the same reason.
    private static let upstreamNotice = """
        Port Radar
        Copyright 2026 Juan Sebastian Solano

        This product includes software developed by Juan Sebastian Solano
        (https://github.com/juansebsol/port-radar-mac).

        Licensed under the Apache License, Version 2.0. Redistributions and
        derivative works must include a readable copy of this notice.
        """

    /// Working artifacts and vendored trees, none of which ship or market the
    /// product: build output, dependencies, and git-ignored process folders.
    private static let excludedDirectoryNames: Set<String> = [
        ".build", ".git", ".next", ".superpowers", "Docs", "content", "dist",
        "node_modules", "out", "outputs",
    ]

    /// Historical design and plan records describe the pre-fork product on
    /// purpose, so they are history rather than shipping or marketing copy.
    private static let excludedRelativePaths: Set<String> = [
        "docs/plans", "docs/superpowers",
    ]

    private static let excludedFileNames: Set<String> = [
        "LICENSE", "package-lock.json",
    ]

    private static let auditedExtensions: Set<String> = [
        "css", "html", "js", "json", "md", "mjs", "plist", "sh", "swift", "ts",
        "tsx", "txt", "yaml", "yml",
    ]

    private static let auditedFileNames: Set<String> = ["Makefile", "NOTICE"]

    /// Drops the exemptions the fork is required or allowed to keep, so the
    /// scan only sees copy that would advertise the removed feature.
    private static func scannableCopy(
        in text: String,
        relativePath: String
    ) -> String {
        let withoutRequiredPhrase = text.replacingOccurrences(
            of: ["tunn", "el-free"].joined(),
            with: "",
            options: [.caseInsensitive]
        )
        guard relativePath == "NOTICE" else { return withoutRequiredPhrase }
        return withoutRequiredPhrase.replacingOccurrences(
            of: upstreamNotice,
            with: ""
        )
    }

    private static func relativePath(of url: URL, in root: URL) -> String {
        url.path.replacingOccurrences(of: root.path + "/", with: "")
    }

    private func repositoryRootURL() throws -> URL {
        let repositoryRoot = try packageRootURL()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: repositoryRoot.appendingPathComponent("NOTICE").path
        ),
            FileManager.default.fileExists(
                atPath: repositoryRoot.path,
                isDirectory: &isDirectory
            ),
            isDirectory.boolValue else {
            throw SourceDiscoveryError.missingRepositoryRoot(repositoryRoot.path)
        }

        return repositoryRoot
    }

    private func auditableFiles(at root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw SourceDiscoveryError.cannotEnumerateSourceRoot(root.path)
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey]
            )
            let name = url.lastPathComponent

            if values.isDirectory == true {
                if Self.excludedDirectoryNames.contains(name)
                    || name.hasSuffix(".app")
                    || Self.excludedRelativePaths.contains(
                        Self.relativePath(of: url, in: root)
                    ) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values.isRegularFile == true,
                  !Self.excludedFileNames.contains(name),
                  Self.auditedExtensions.contains(url.pathExtension)
                    || Self.auditedFileNames.contains(name) else {
                continue
            }
            files.append(url)
        }

        return files.sorted { $0.path < $1.path }
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
    case missingRepositoryRoot(String)
    case missingPackageRoot(String)
    case missingSourceRoot(String)
    case cannotEnumerateSourceRoot(String)
    case cannotDecodePropertyList(String)
}
