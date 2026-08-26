// Modification notice: Changed in 2026 for the local AI and optional Ollama fallback contribution, and for the Port Radar Offline fork product identity.
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
    private let conversationError: (any Error & Sendable)?
    private var availabilityModelIDs: [String?] = []
    private var conversationModelIDs: [String?] = []
    private var conversationContexts: [SanitizedProcessContext] = []

    init(
        id: LocalAIProviderID,
        result: LocalAIAvailability,
        conversationProviderID: LocalAIProviderID? = nil,
        conversationError: (any Error & Sendable)? = nil
    ) {
        self.id = id
        self.result = result
        self.conversationProviderID = conversationProviderID ?? id
        self.conversationError = conversationError
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
        if let conversationError { throw conversationError }
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

    private var closeCount = 0

    init(providerID: LocalAIProviderID) {
        self.providerID = providerID
    }

    func streamResponse(to prompt: String) async throws -> LocalAITextStream {
        LocalAITextStream { continuation in
            continuation.yield("stub")
            continuation.finish()
        }
    }

    func close() async {
        closeCount += 1
    }

    func recordedCloseCount() -> Int { closeCount }
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

/// Hands the test control over when conversation creation returns, so a
/// cancellation can land while the private service is already owned.
private actor ControlledCreationProvider: LocalAIProvider {
    nonisolated let id: LocalAIProviderID

    private let conversation: ConversationStub
    private var didStartCreation = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var creationContinuation:
        CheckedContinuation<any LocalAIConversation, Never>?

    init(id: LocalAIProviderID, conversation: ConversationStub) {
        self.id = id
        self.conversation = conversation
    }

    func availability(modelID: String?) async -> LocalAIAvailability {
        .available
    }

    func makeConversation(
        context: SanitizedProcessContext,
        modelID: String?
    ) async throws -> any LocalAIConversation {
        didStartCreation = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        return await withCheckedContinuation { continuation in
            creationContinuation = continuation
        }
    }

    func waitUntilCreationStarts() async {
        guard !didStartCreation else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func completeCreation() {
        creationContinuation?.resume(returning: conversation)
        creationContinuation = nil
    }
}

private struct ResolverLeaseSnapshot: Equatable, Sendable {
    let acquires: Int
    let releases: Int
}

private actor ResolverLeaseSpy {
    private var acquires = 0
    private var releases = 0

    func acquire() async throws -> OllamaServiceLease {
        acquires += 1
        return OllamaServiceLease.testInstance(
            endpoint: OllamaServiceEndpoint(
                baseURL: URL(string: "http://127.0.0.1:11435")!,
                processIdentifier: 5150
            )
        ) {
            await self.recordRelease()
        }
    }

    func snapshot() -> ResolverLeaseSnapshot {
        ResolverLeaseSnapshot(acquires: acquires, releases: releases)
    }

    private func recordRelease() {
        releases += 1
    }
}

private struct ResolverStreamClient: OllamaClientProtocol {
    func version() async throws -> String { "test" }
    func localModels() async throws -> [OllamaModel] { [] }
    func validateLocalModel(_ id: String) async throws {}

    func chatStream(
        model: String,
        messages: [OllamaChatMessage]
    ) async throws -> LocalAITextStream {
        LocalAITextStream { continuation in
            continuation.yield("Local answer")
            continuation.finish()
        }
    }

    func unload(model: String) async {}
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

    func testCancellationDuringCreationClosesTheOwnedConversation() async {
        let conversation = ConversationStub(providerID: .ollama)
        let ollama = ControlledCreationProvider(
            id: .ollama,
            conversation: conversation
        )
        let apple = ProviderSpy(
            id: .apple,
            result: .unavailable(.appleUnavailable("disabled"))
        )
        let resolver = AIProviderResolver(apple: apple, ollama: ollama)
        let context = context
        let resolution = Task {
            try await resolver.resolve(
                preference: .ollama,
                ollamaModelID: "qwen3:4b",
                context: context
            )
        }

        await ollama.waitUntilCreationStarts()
        resolution.cancel()
        await ollama.completeCreation()

        do {
            _ = try await resolution.value
            XCTFail("Expected cancellation to stop resolution")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let closeCount = await conversation.recordedCloseCount()
        XCTAssertEqual(closeCount, 1)
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

    func testAutomaticFallsBackToOllamaWithoutAnAvailabilityProbe() async throws {
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
        XCTAssertEqual(ollamaSnapshot.availabilityCalls, 0)
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

    func testForcedOllamaCreatesDirectlyWithoutProbingEitherProvider() async throws {
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
        XCTAssertEqual(ollamaSnapshot.availabilityCalls, 0)
        XCTAssertEqual(ollamaSnapshot.conversationCalls, 1)
        XCTAssertEqual(ollamaSnapshot.conversationModelIDs, ["qwen3:4b"])
        XCTAssertEqual(ollamaSnapshot.conversationContexts, [context])
    }

    func testAutomaticSurfacesOllamaCreationErrorWhenNeitherIsAvailable() async {
        let expectedError = LocalAIError.ollamaModelRequired
        let apple = ProviderSpy(
            id: .apple,
            result: .unavailable(.appleUnavailable("disabled"))
        )
        let ollama = ProviderSpy(
            id: .ollama,
            result: .available,
            conversationError: expectedError
        )
        let resolver = AIProviderResolver(apple: apple, ollama: ollama)

        do {
            _ = try await resolver.resolve(
                preference: .automatic,
                ollamaModelID: nil,
                context: context
            )
            XCTFail("Expected Automatic to surface Ollama's creation error")
        } catch {
            XCTAssertEqual(error as? LocalAIError, expectedError)
        }

        let appleSnapshot = await apple.snapshot()
        let ollamaSnapshot = await ollama.snapshot()
        XCTAssertEqual(appleSnapshot.availabilityCalls, 1)
        XCTAssertEqual(appleSnapshot.conversationCalls, 0)
        XCTAssertEqual(ollamaSnapshot.availabilityCalls, 0)
        XCTAssertEqual(ollamaSnapshot.conversationCalls, 1)
    }

    func testAutomaticOllamaFallbackAcquiresThePrivateServiceExactlyOnce() async throws {
        let leases = ResolverLeaseSpy()
        let apple = ProviderSpy(
            id: .apple,
            result: .unavailable(.appleUnavailable("disabled"))
        )
        let ollama = OllamaProvider(
            acquireLease: { try await leases.acquire() },
            makeClient: { _ in ResolverStreamClient() }
        )
        let resolver = AIProviderResolver(apple: apple, ollama: ollama)

        let resolved = try await resolver.resolve(
            preference: .automatic,
            ollamaModelID: "qwen3:4b",
            context: context
        )

        XCTAssertEqual(resolved.providerID, .ollama)
        let beforeClose = await leases.snapshot()
        XCTAssertEqual(
            beforeClose,
            ResolverLeaseSnapshot(acquires: 1, releases: 0)
        )

        await resolved.conversation.close()

        let afterClose = await leases.snapshot()
        XCTAssertEqual(
            afterClose,
            ResolverLeaseSnapshot(acquires: 1, releases: 1)
        )
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
            (
                .ollamaNotInstalled,
                "Ollama is not installed. Install it separately, then try again."
            ),
            (
                .ollamaPrivateServiceUnavailable,
                "Unable to start the private local Ollama service."
            ),
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
                "Ollama redirected outside Port Radar Offline's local-only boundary."
            ),
            (.timedOut, "The local model took too long to respond."),
            (.malformedResponse, "Ollama returned an unreadable response.")
        ]

        for (error, expectedDescription) in cases {
            XCTAssertEqual(error.errorDescription, expectedDescription)
        }
    }
}
