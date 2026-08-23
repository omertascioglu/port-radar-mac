import XCTest
@testable import DevPort

private struct ProviderSpySnapshot: Equatable, Sendable {
    let availabilityCalls: Int
    let availabilityModelIDs: [String?]
    let conversationCalls: Int
    let conversationModelIDs: [String?]
    let conversationContexts: [SanitizedProcessContext]
}

private actor ProviderSpy: LocalAIProvider {
    nonisolated let id: LocalAIProviderID

    private let result: LocalAIAvailability
    private let conversationProviderID: LocalAIProviderID
    private var availabilityModelIDs: [String?] = []
    private var conversationModelIDs: [String?] = []
    private var conversationContexts: [SanitizedProcessContext] = []

    init(
        id: LocalAIProviderID,
        result: LocalAIAvailability,
        conversationProviderID: LocalAIProviderID? = nil
    ) {
        self.id = id
        self.result = result
        self.conversationProviderID = conversationProviderID ?? id
    }

    func availability(modelID: String?) async -> LocalAIAvailability {
        availabilityModelIDs.append(modelID)
        return result
    }

    func makeConversation(
        context: SanitizedProcessContext,
        modelID: String?
    ) async throws -> any LocalAIConversation {
        conversationModelIDs.append(modelID)
        conversationContexts.append(context)
        return ConversationStub(providerID: conversationProviderID)
    }

    func snapshot() -> ProviderSpySnapshot {
        ProviderSpySnapshot(
            availabilityCalls: availabilityModelIDs.count,
            availabilityModelIDs: availabilityModelIDs,
            conversationCalls: conversationModelIDs.count,
            conversationModelIDs: conversationModelIDs,
            conversationContexts: conversationContexts
        )
    }
}

private actor ConversationStub: LocalAIConversation {
    nonisolated let providerID: LocalAIProviderID

    init(providerID: LocalAIProviderID) {
        self.providerID = providerID
    }

    func respond(to prompt: String) async throws -> String { "stub" }
    func close() async {}
}

private actor ControlledAvailabilityProvider: LocalAIProvider {
    nonisolated let id: LocalAIProviderID

    private var didStartAvailability = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var availabilityContinuation:
        CheckedContinuation<LocalAIAvailability, Never>?
    private var conversationCalls = 0

    init(id: LocalAIProviderID) {
        self.id = id
    }

    func availability(modelID: String?) async -> LocalAIAvailability {
        didStartAvailability = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        return await withCheckedContinuation { continuation in
            availabilityContinuation = continuation
        }
    }

    func makeConversation(
        context: SanitizedProcessContext,
        modelID: String?
    ) async throws -> any LocalAIConversation {
        conversationCalls += 1
        return ConversationStub(providerID: id)
    }

    func waitUntilAvailabilityStarts() async {
        guard !didStartAvailability else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func completeAvailability(with result: LocalAIAvailability) {
        availabilityContinuation?.resume(returning: result)
        availabilityContinuation = nil
    }

    func conversationCallCount() -> Int { conversationCalls }
}

final class AIProviderResolverTests: XCTestCase {
    private let context = SanitizedProcessContext(text: "port: 3000")

    func testCancellationAfterAvailabilityProbeSkipsConversationCreation() async {
        let apple = ControlledAvailabilityProvider(id: .apple)
        let ollama = ProviderSpy(id: .ollama, result: .available)
        let resolver = AIProviderResolver(apple: apple, ollama: ollama)
        let context = context
        let resolution = Task {
            try await resolver.resolve(
                preference: .automatic,
                ollamaModelID: "qwen3:4b",
                context: context
            )
        }

        await apple.waitUntilAvailabilityStarts()
        resolution.cancel()
        await apple.completeAvailability(with: .available)

        do {
            _ = try await resolution.value
            XCTFail("Expected cancellation to stop resolution")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let appleConversationCalls = await apple.conversationCallCount()
        let ollamaSnapshot = await ollama.snapshot()
        XCTAssertEqual(appleConversationCalls, 0)
        XCTAssertEqual(ollamaSnapshot.availabilityCalls, 0)
        XCTAssertEqual(ollamaSnapshot.conversationCalls, 0)
    }

    func testResolvedProviderIdentityComesFromConversation() async throws {
        let apple = ProviderSpy(
            id: .apple,
            result: .available,
            conversationProviderID: .ollama
        )
        let ollama = ProviderSpy(id: .ollama, result: .available)
        let resolver = AIProviderResolver(apple: apple, ollama: ollama)

        let resolved = try await resolver.resolve(
            preference: .automatic,
            ollamaModelID: "qwen3:4b",
            context: context
        )

        XCTAssertEqual(resolved.providerID, .ollama)
        XCTAssertEqual(resolved.badgeText, "Ollama · Local")
    }

    func testAutomaticPrefersAppleWithoutProbingOllama() async throws {
        let apple = ProviderSpy(id: .apple, result: .available)
        let ollama = ProviderSpy(id: .ollama, result: .available)
        let resolver = AIProviderResolver(apple: apple, ollama: ollama)

        let resolved = try await resolver.resolve(
            preference: .automatic,
            ollamaModelID: "qwen3:4b",
            context: context
        )

        XCTAssertEqual(resolved.providerID, .apple)
        XCTAssertEqual(resolved.badgeText, "Apple · On-device")
        let appleSnapshot = await apple.snapshot()
        let ollamaSnapshot = await ollama.snapshot()
        XCTAssertEqual(appleSnapshot.availabilityCalls, 1)
        XCTAssertEqual(appleSnapshot.availabilityModelIDs, [nil])
        XCTAssertEqual(appleSnapshot.conversationCalls, 1)
        XCTAssertEqual(appleSnapshot.conversationModelIDs, [nil])
        XCTAssertEqual(ollamaSnapshot.availabilityCalls, 0)
        XCTAssertEqual(ollamaSnapshot.conversationCalls, 0)
    }

    func testAutomaticFallsBackToOllama() async throws {
        let apple = ProviderSpy(
            id: .apple,
            result: .unavailable(.appleUnavailable("disabled"))
        )
        let ollama = ProviderSpy(id: .ollama, result: .available)
        let resolver = AIProviderResolver(apple: apple, ollama: ollama)

        let resolved = try await resolver.resolve(
            preference: .automatic,
            ollamaModelID: "qwen3:4b",
            context: context
        )

        XCTAssertEqual(resolved.providerID, .ollama)
        XCTAssertEqual(resolved.badgeText, "Ollama · Local")
        let appleSnapshot = await apple.snapshot()
        let ollamaSnapshot = await ollama.snapshot()
        XCTAssertEqual(appleSnapshot.availabilityCalls, 1)
        XCTAssertEqual(appleSnapshot.conversationCalls, 0)
        XCTAssertEqual(ollamaSnapshot.availabilityCalls, 1)
        XCTAssertEqual(ollamaSnapshot.availabilityModelIDs, ["qwen3:4b"])
        XCTAssertEqual(ollamaSnapshot.conversationCalls, 1)
        XCTAssertEqual(ollamaSnapshot.conversationModelIDs, ["qwen3:4b"])
    }

    func testForcedAppleUnavailableThrowsExactErrorWithoutProbingOllama() async {
        let expectedError = LocalAIError.appleUnavailable("disabled")
        let apple = ProviderSpy(
            id: .apple,
            result: .unavailable(expectedError)
        )
        let ollama = ProviderSpy(id: .ollama, result: .available)
        let resolver = AIProviderResolver(apple: apple, ollama: ollama)

        do {
            _ = try await resolver.resolve(
                preference: .apple,
                ollamaModelID: "qwen3:4b",
                context: context
            )
            XCTFail("Expected forced Apple to stay unavailable")
        } catch {
            XCTAssertEqual(error as? LocalAIError, expectedError)
        }

        let appleSnapshot = await apple.snapshot()
        let ollamaSnapshot = await ollama.snapshot()
        XCTAssertEqual(appleSnapshot.availabilityCalls, 1)
        XCTAssertEqual(appleSnapshot.conversationCalls, 0)
        XCTAssertEqual(ollamaSnapshot.availabilityCalls, 0)
        XCTAssertEqual(ollamaSnapshot.conversationCalls, 0)
    }

    func testForcedOllamaWinsWithoutProbingApple() async throws {
        let apple = ProviderSpy(id: .apple, result: .available)
        let ollama = ProviderSpy(id: .ollama, result: .available)
        let resolver = AIProviderResolver(apple: apple, ollama: ollama)

        let resolved = try await resolver.resolve(
            preference: .ollama,
            ollamaModelID: "qwen3:4b",
            context: context
        )

        XCTAssertEqual(resolved.providerID, .ollama)
        let appleSnapshot = await apple.snapshot()
        let ollamaSnapshot = await ollama.snapshot()
        XCTAssertEqual(appleSnapshot.availabilityCalls, 0)
        XCTAssertEqual(appleSnapshot.conversationCalls, 0)
        XCTAssertEqual(ollamaSnapshot.availabilityCalls, 1)
        XCTAssertEqual(ollamaSnapshot.availabilityModelIDs, ["qwen3:4b"])
        XCTAssertEqual(ollamaSnapshot.conversationCalls, 1)
        XCTAssertEqual(ollamaSnapshot.conversationModelIDs, ["qwen3:4b"])
        XCTAssertEqual(ollamaSnapshot.conversationContexts, [context])
    }

    func testAutomaticSurfacesOllamaErrorWhenNeitherProviderIsAvailable() async {
        let expectedError = LocalAIError.ollamaNotRunning
        let apple = ProviderSpy(
            id: .apple,
            result: .unavailable(.appleUnavailable("disabled"))
        )
        let ollama = ProviderSpy(
            id: .ollama,
            result: .unavailable(expectedError)
        )
        let resolver = AIProviderResolver(apple: apple, ollama: ollama)

        do {
            _ = try await resolver.resolve(
                preference: .automatic,
                ollamaModelID: "qwen3:4b",
                context: context
            )
            XCTFail("Expected Automatic to surface Ollama's availability error")
        } catch {
            XCTAssertEqual(error as? LocalAIError, expectedError)
        }

        let appleSnapshot = await apple.snapshot()
        let ollamaSnapshot = await ollama.snapshot()
        XCTAssertEqual(appleSnapshot.availabilityCalls, 1)
        XCTAssertEqual(appleSnapshot.conversationCalls, 0)
        XCTAssertEqual(ollamaSnapshot.availabilityCalls, 1)
        XCTAssertEqual(ollamaSnapshot.conversationCalls, 0)
    }

    func testProviderBadgesAndPreferenceMetadataAreStable() {
        XCTAssertEqual(LocalAIProviderID.apple.badgeText, "Apple · On-device")
        XCTAssertEqual(LocalAIProviderID.ollama.badgeText, "Ollama · Local")
        XCTAssertEqual(
            LocalAIProviderPreference.allCases.map(\.displayName),
            ["Automatic", "Apple Intelligence", "Ollama"]
        )
        XCTAssertEqual(
            LocalAIProviderPreference.allCases.map(\.id),
            ["automatic", "apple", "ollama"]
        )
        XCTAssertEqual(LocalAIProviderPreference.persistedValue(nil), .automatic)
        XCTAssertEqual(
            LocalAIProviderPreference.persistedValue("unknown-provider"),
            .automatic
        )
    }

    func testLocalAIErrorsHaveBoundedUserFacingDescriptions() {
        let cases: [(LocalAIError, String)] = [
            (.appleUnavailable("Apple Intelligence is disabled."), "Apple Intelligence is disabled."),
            (.ollamaNotRunning, "Ollama is not running."),
            (.ollamaModelRequired, "Choose an installed local Ollama model."),
            (
                .ollamaModelUnavailable,
                "The selected local Ollama model is no longer available."
            ),
            (
                .remoteModelRejected,
                "Cloud and remote Ollama models are not allowed."
            ),
            (
                .unsafeLocalEndpoint,
                "Ollama redirected outside Port Radar's local-only boundary."
            ),
            (.timedOut, "The local model took too long to respond."),
            (.malformedResponse, "Ollama returned an unreadable response.")
        ]

        for (error, expectedDescription) in cases {
            XCTAssertEqual(error.errorDescription, expectedDescription)
        }
    }
}
