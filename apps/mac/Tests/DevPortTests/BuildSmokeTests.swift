import XCTest
@testable import DevPort

final class BuildSmokeTests: XCTestCase {
    func testProviderPreferenceDefaultsToAutomatic() {
        XCTAssertEqual(
            LocalAIProviderPreference.persistedValue(nil),
            .automatic
        )
    }
}
