import Foundation
import XCTest
@testable import DevPort

private actor StatusTextOllamaClientStub: OllamaClientProtocol {
    enum Response: Sendable {
        case models([OllamaModel])
        case notRunning
    }

    private var responses: [Response]
    private var localModelCallCount = 0

    init(_ responses: [Response]) {
        self.responses = responses
    }

    func version() async throws -> String { "test" }

    func localModels() async throws -> [OllamaModel] {
        localModelCallCount += 1
        guard !responses.isEmpty else {
            throw LocalAIError.malformedResponse
        }

        switch responses.removeFirst() {
        case .models(let models):
            return models
        case .notRunning:
            throw LocalAIError.ollamaNotRunning
        }
    }

    func validateLocalModel(_ id: String) async throws {
        throw LocalAIError.ollamaModelUnavailable
    }

    func chat(
        model: String,
        messages: [OllamaChatMessage]
    ) async throws -> String {
        throw LocalAIError.malformedResponse
    }

    func unload(model: String) async {}

    func callCount() -> Int { localModelCallCount }
}

private actor StatusTextRetrySleeper {
    private var callCount = 0
    private var continuations:
        [CheckedContinuation<Void, any Error>] = []

    func sleep(_ duration: Duration) async throws {
        callCount += 1
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForCall() async {
        while callCount == 0 {
            await Task.yield()
        }
    }

    func resumeAll() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

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

    func testOpenOllamaRetriesUntilValidatedModelsAreReady() async {
        let client = StatusTextOllamaClientStub([
            .notRunning,
            .notRunning,
            .models([qwen]),
        ])
        let (preferences, cleanup) = makePreferences()
        defer { cleanup() }
        var didOpenApplication = false
        let model = OllamaSettingsModel(
            client: client,
            preferences: preferences,
            openApplication: { didOpenApplication = true },
            sleep: { _ in }
        )

        model.openOllamaAndRetry(selectedModelID: "")

        await waitUntil { model.state == .ready([self.qwen]) }
        let callCount = await client.callCount()
        XCTAssertTrue(didOpenApplication)
        XCTAssertEqual(callCount, 3)
        XCTAssertFalse(model.showsDownloadLink)
    }

    func testOpenOllamaFailureOffersExplicitDownloadLink() async {
        let client = StatusTextOllamaClientStub([])
        let (preferences, cleanup) = makePreferences()
        defer { cleanup() }
        let model = OllamaSettingsModel(
            client: client,
            preferences: preferences,
            openApplication: { throw LocalAIError.ollamaNotRunning },
            sleep: { _ in }
        )

        model.openOllamaAndRetry(selectedModelID: "")

        await waitUntil {
            model.state == .failed("Ollama app was not found.")
        }
        let callCount = await client.callCount()
        XCTAssertTrue(model.showsDownloadLink)
        XCTAssertEqual(callCount, 0)
    }

    func testCancelPreventsRetryFromPublishingAfterDisappear() async {
        let client = StatusTextOllamaClientStub([
            .notRunning,
            .models([qwen]),
        ])
        let sleeper = StatusTextRetrySleeper()
        let (preferences, cleanup) = makePreferences()
        defer { cleanup() }
        let model = OllamaSettingsModel(
            client: client,
            preferences: preferences,
            openApplication: {},
            sleep: { duration in try await sleeper.sleep(duration) }
        )

        model.openOllamaAndRetry(selectedModelID: "")
        await sleeper.waitForCall()
        model.cancelRefresh()
        await sleeper.resumeAll()
        for _ in 0..<20 { await Task.yield() }

        let callCount = await client.callCount()
        XCTAssertEqual(callCount, 1)
        XCTAssertNotEqual(model.state, .ready([qwen]))
    }

    private func makePreferences() -> (Preferences, () -> Void) {
        let suiteName = "LocalAIStatusTextTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (
            Preferences(defaults: defaults),
            { defaults.removePersistentDomain(forName: suiteName) }
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition was not met", file: file, line: line)
    }
}
