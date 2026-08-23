import XCTest
@testable import DevPort

final class AppleProviderFallbackTests: XCTestCase {
    func testAppleProviderAlwaysIdentifiesAsApple() {
        XCTAssertEqual(AppleFoundationModelProvider().id, .apple)
    }

    func testLiveResolverComposesAppleAndOllamaProvidersWithoutDiscovery() {
        let resolver = AIProviderResolver.live

        XCTAssertEqual(resolver.apple.id, .apple)
        XCTAssertEqual(resolver.ollama.id, .ollama)
    }

    #if !canImport(FoundationModels)
    func testAppleProviderIsUnavailableWithoutFramework() async {
        let availability = await AppleFoundationModelProvider().availability(
            modelID: nil
        )

        XCTAssertEqual(
            availability,
            .unavailable(.appleUnavailable(
                "Apple Intelligence requires macOS 26 or later."
            ))
        )
    }

    func testAppleProviderCannotCreateConversationWithoutFramework() async {
        do {
            _ = try await AppleFoundationModelProvider().makeConversation(
                context: SanitizedProcessContext(text: "port: 3000"),
                modelID: nil
            )
            XCTFail("Expected Apple provider to be unavailable")
        } catch {
            XCTAssertEqual(
                error as? LocalAIError,
                .appleUnavailable(
                    "Apple Intelligence requires macOS 26 or later."
                )
            )
        }
    }
    #endif
}
