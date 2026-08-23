import Foundation
import XCTest
@testable import DevPort

@MainActor
final class LocalAIPreferencesTests: XCTestCase {
    func testMissingAndUnknownPreferenceBecomeAutomatic() {
        XCTAssertEqual(
            LocalAIProviderPreference.persistedValue(nil),
            .automatic
        )
        XCTAssertEqual(
            LocalAIProviderPreference.persistedValue("future-provider"),
            .automatic
        )
    }

    func testProviderPreferenceLoadsAndRoundTripsInInjectedDefaults() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("ollama", forKey: "localAIProvider")
        let preferences = Preferences(defaults: defaults)

        XCTAssertEqual(preferences.localAIProviderPreference, .ollama)

        preferences.localAIProviderPreference = .apple

        XCTAssertEqual(defaults.string(forKey: "localAIProvider"), "apple")
        XCTAssertEqual(
            Preferences(defaults: defaults).localAIProviderPreference,
            .apple
        )
    }

    func testSelectedOllamaModelRoundTrips() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = Preferences(defaults: defaults)

        preferences.ollamaModelID = "qwen3:4b"

        XCTAssertEqual(defaults.string(forKey: "ollamaModel"), "qwen3:4b")
        XCTAssertEqual(
            Preferences(defaults: defaults).ollamaModelID,
            "qwen3:4b"
        )
    }

    func testEmptyOllamaModelStaysEmpty() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = Preferences(defaults: defaults)

        XCTAssertEqual(preferences.ollamaModelID, "")

        preferences.ollamaModelID = ""

        XCTAssertEqual(defaults.string(forKey: "ollamaModel"), "")
        XCTAssertEqual(Preferences(defaults: defaults).ollamaModelID, "")
    }

    func testLocalAIPreferencesPersistOnlyProviderAndModelIdentifier() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = Preferences(defaults: defaults)

        preferences.localAIProviderPreference = .ollama
        preferences.ollamaModelID = "qwen3:4b"

        XCTAssertEqual(
            Set((defaults.persistentDomain(forName: suiteName) ?? [:]).keys),
            ["localAIProvider", "ollamaModel"]
        )
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "LocalAIPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
