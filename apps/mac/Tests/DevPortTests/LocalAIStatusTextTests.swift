import Foundation
import XCTest
@testable import DevPort

@MainActor
final class LocalAIStatusTextTests: XCTestCase {
    private let qwen = OllamaModel(
        id: "qwen3:4b",
        size: 2_500_000_000,
        format: "gguf"
    )
    private let llama = OllamaModel(
        id: "llama3.2:3b",
        size: 2_000_000_000,
        format: "gguf"
    )

    func testIdleAndLoadingStatusText() {
        XCTAssertEqual(
            OllamaSettingsModel.State.idle.statusText,
            "Ollama status has not been checked"
        )
        XCTAssertEqual(
            OllamaSettingsModel.State.loading.statusText,
            "Checking Ollama…"
        )
    }

    func testReadyStatusCountsLocalModelsWithSingularAndPluralCopy() {
        XCTAssertEqual(
            OllamaSettingsModel.State.ready([qwen]).statusText,
            "Ollama is running · 1 local model"
        )
        XCTAssertEqual(
            OllamaSettingsModel.State.ready([qwen, llama]).statusText,
            "Ollama is running · 2 local models"
        )
    }

    func testReadyEmptyStatusText() {
        XCTAssertEqual(
            OllamaSettingsModel.State.ready([]).statusText,
            "No local Ollama models found"
        )
    }

    func testNotRunningStatusText() {
        XCTAssertEqual(
            OllamaSettingsModel.State.notRunning.statusText,
            "Ollama is not running"
        )
    }

    func testFailedStatusTextUsesBoundedMessage() {
        XCTAssertEqual(
            OllamaSettingsModel.State.failed(
                "Unable to check local Ollama models."
            ).statusText,
            "Unable to check local Ollama models."
        )
    }

    func testMissingOllamaStatusTextNamesASeparateInstallation() throws {
        let message = try XCTUnwrap(
            LocalAIError.ollamaNotInstalled.errorDescription
        )

        XCTAssertEqual(
            message,
            "Ollama is not installed. Install it separately, then try again."
        )
        XCTAssertEqual(
            OllamaSettingsModel.State.failed(message).statusText,
            "Ollama is not installed. Install it separately, then try again."
        )
        XCTAssertTrue(message.hasPrefix("Ollama is not installed."))
        XCTAssertFalse(message.lowercased().contains("http"))
        XCTAssertFalse(message.contains("Download"))
    }

    func testNoLocalModelsOffersPlainNonClickableGuidance() throws {
        let guidance = try XCTUnwrap(
            OllamaSettingsModel.State.ready([]).installationGuidance
        )

        XCTAssertEqual(
            guidance,
            "Install a local model with Ollama outside Port Radar Offline, "
                + "then check again."
        )
        XCTAssertFalse(guidance.lowercased().contains("http"))
        XCTAssertFalse(guidance.contains("Download"))
        XCTAssertFalse(guidance.lowercased().contains("click"))
    }

    func testEveryOtherStateOffersNoInstallationGuidance() {
        let states: [OllamaSettingsModel.State] = [
            .idle,
            .loading,
            .ready([qwen]),
            .notRunning,
            .failed("Unable to check local Ollama models."),
        ]

        for state in states {
            XCTAssertNil(state.installationGuidance, "\(state)")
        }
    }

    func testCheckTitleAsksForAFirstCheckThenOffersARefresh() {
        XCTAssertEqual(
            OllamaSettingsModel.State.idle.checkButtonTitle,
            "Check local models"
        )

        let checkedStates: [OllamaSettingsModel.State] = [
            .loading,
            .ready([]),
            .ready([qwen]),
            .notRunning,
            .failed("Unable to check local Ollama models."),
        ]
        for state in checkedStates {
            XCTAssertEqual(state.checkButtonTitle, "Refresh", "\(state)")
        }
    }

    func testOllamaControlsAreVisibleForAutomaticAndOllamaOnly() {
        XCTAssertTrue(LocalAIProviderPreference.automatic.usesOllamaControls)
        XCTAssertFalse(LocalAIProviderPreference.apple.usesOllamaControls)
        XCTAssertTrue(LocalAIProviderPreference.ollama.usesOllamaControls)
    }

    func testRemoteOnlyResponseProducesReadyEmptyStatusText() throws {
        let data = Data(
            """
            {
              "models": [{
                "name": "gpt-oss:120b-cloud",
                "model": "gpt-oss:120b-cloud",
                "remote_model": "gpt-oss:120b",
                "remote_host": "https://ollama.com",
                "size": 1024,
                "digest": "sha256:remote",
                "details": { "format": "gguf" }
              }]
            }
            """.utf8
        )
        let response = try JSONDecoder().decode(
            OllamaTagsResponse.self,
            from: data
        )

        XCTAssertEqual(response.validatedLocalModels, [])
        XCTAssertEqual(
            OllamaSettingsModel.State.ready(
                response.validatedLocalModels
            ).statusText,
            "No local Ollama models found"
        )
    }

    func testSettingsOffersOnlyOfflineLocalOllamaControls() throws {
        let text = try settingsViewSource()

        XCTAssertTrue(
            text.contains("Text(\"Offline — data never leaves this Mac.\")")
        )
        XCTAssertTrue(
            text.contains("Button(ollamaSettings.state.checkButtonTitle)")
        )
        XCTAssertTrue(text.contains("ollamaSettings.refresh("))
        XCTAssertTrue(text.contains("ollamaSettings.cancelRefresh()"))
        XCTAssertTrue(
            text.contains("ollamaSettings.state.installationGuidance")
        )
        XCTAssertTrue(
            text.contains("selection: $preferences.ollamaModelID")
        )
        XCTAssertTrue(
            text.contains("selection: $preferences.localAIProviderPreference")
        )
        XCTAssertFalse(text.contains("Link("))
        XCTAssertFalse(text.contains("URL("))
        XCTAssertFalse(text.lowercased().contains("http"))
        XCTAssertFalse(text.contains("Download"))
        XCTAssertFalse(text.contains("Open Ollama"))
        XCTAssertFalse(text.contains("openOllama"))
        XCTAssertFalse(text.contains("showsDownloadLink"))
    }

    func testShippingSourcesOfferNoOllamaDownloadOrLaunchPath() throws {
        let sourceRoot = try sourceRootURL()

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: sourceRoot
                    .appendingPathComponent("Actions/OllamaApplication.swift")
                    .path
            )
        )

        let forbidden = ["ollama.com/download", "openOllama", "showsDownloadLink"]
        let violations = try swiftSources(at: sourceRoot).flatMap { url in
            let text = try String(contentsOf: url, encoding: .utf8)
            let relativePath = url.path.replacingOccurrences(
                of: sourceRoot.path + "/",
                with: ""
            )
            return forbidden.compactMap { token in
                text.contains(token) ? "\(relativePath): \(token)" : nil
            }
        }

        XCTAssertEqual(violations, [])
    }

    private func settingsViewSource() throws -> String {
        let url = try sourceRootURL()
            .appendingPathComponent("Views/SettingsView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceRootURL() throws -> URL {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DevPort", isDirectory: true)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: sourceRoot.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw StatusTextSourceError.missingSourceRoot(sourceRoot.path)
        }

        return sourceRoot
    }

    private func swiftSources(at sourceRoot: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw StatusTextSourceError.cannotEnumerate(sourceRoot.path)
        }

        return try enumerator.compactMap { item in
            guard let url = item as? URL,
                  url.pathExtension == "swift",
                  try url.resourceValues(forKeys: [.isRegularFileKey])
                    .isRegularFile == true else {
                return nil
            }
            return url
        }
        .sorted { $0.path < $1.path }
    }
}

private enum StatusTextSourceError: Error {
    case missingSourceRoot(String)
    case cannotEnumerate(String)
}
