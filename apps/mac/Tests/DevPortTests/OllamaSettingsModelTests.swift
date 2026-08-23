import Foundation
import XCTest
@testable import DevPort

private actor SettingsOllamaClientSpy: OllamaClientProtocol {
    enum Response: Sendable {
        case models([OllamaModel])
        case notRunning
        case timedOut
        case rawFailure(String)
        case suspended(Int)
    }

    private var responses: [Response]
    private var localModelCalls = 0
    private var continuations:
        [Int: CheckedContinuation<[OllamaModel], any Error>] = [:]

    init(_ responses: [Response]) {
        self.responses = responses
    }

    func version() async throws -> String { "test" }

    func localModels() async throws -> [OllamaModel] {
        localModelCalls += 1
        guard !responses.isEmpty else {
            throw LocalAIError.malformedResponse
        }

        switch responses.removeFirst() {
        case .models(let models):
            return models
        case .notRunning:
            throw LocalAIError.ollamaNotRunning
        case .timedOut:
            throw LocalAIError.timedOut
        case .rawFailure(let secret):
            throw NSError(
                domain: "synthetic-\(secret)",
                code: 1
            )
        case .suspended(let identifier):
            return try await withCheckedThrowingContinuation { continuation in
                continuations[identifier] = continuation
            }
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

    func waitForCallCount(_ expected: Int) async {
        while localModelCalls < expected {
            await Task.yield()
        }
    }

    func resume(_ identifier: Int, returning models: [OllamaModel]) {
        continuations.removeValue(forKey: identifier)?.resume(returning: models)
    }
}

@MainActor
final class OllamaSettingsModelTests: XCTestCase {
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

    func testRunningServicePresentsValidatedLocalModels() async {
        let client = SettingsOllamaClientSpy([.models([qwen, llama])])
        let (preferences, cleanup) = makePreferences()
        defer { cleanup() }
        let model = OllamaSettingsModel(
            client: client,
            preferences: preferences
        )

        XCTAssertEqual(model.state, .idle)

        model.refresh(selectedModelID: "")

        XCTAssertEqual(model.state, .loading)
        await waitUntil { model.state == .ready([self.qwen, self.llama]) }
        XCTAssertEqual(model.state, .ready([qwen, llama]))
    }

    func testStoppedServiceIsNotRunning() async {
        let client = SettingsOllamaClientSpy([.notRunning])
        let (preferences, cleanup) = makePreferences()
        defer { cleanup() }
        let model = OllamaSettingsModel(
            client: client,
            preferences: preferences
        )

        model.refresh(selectedModelID: "")

        await waitUntil { model.state == .notRunning }
        XCTAssertEqual(model.state, .notRunning)
    }

    func testRunningServiceWithNoValidatedModelsIsReadyAndEmpty() async {
        let client = SettingsOllamaClientSpy([.models([])])
        let (preferences, cleanup) = makePreferences()
        defer { cleanup() }
        let model = OllamaSettingsModel(
            client: client,
            preferences: preferences
        )

        model.refresh(selectedModelID: "")

        await waitUntil { model.state == .ready([]) }
        XCTAssertEqual(model.state, .ready([]))
        XCTAssertNotEqual(model.state, .notRunning)
    }

    func testDisappearedSelectionIsCleared() async {
        let client = SettingsOllamaClientSpy([.models([llama])])
        let (preferences, cleanup) = makePreferences()
        defer { cleanup() }
        preferences.ollamaModelID = qwen.id
        let model = OllamaSettingsModel(
            client: client,
            preferences: preferences
        )

        model.refresh(selectedModelID: qwen.id)

        await waitUntil { model.state == .ready([self.llama]) }
        XCTAssertEqual(preferences.ollamaModelID, "")
    }

    func testSelectionChangedDuringRefreshIsNotCleared() async {
        let client = SettingsOllamaClientSpy([.suspended(1)])
        let (preferences, cleanup) = makePreferences()
        defer { cleanup() }
        preferences.ollamaModelID = qwen.id
        let model = OllamaSettingsModel(
            client: client,
            preferences: preferences
        )

        model.refresh(selectedModelID: qwen.id)
        await client.waitForCallCount(1)
        preferences.ollamaModelID = llama.id
        await client.resume(1, returning: [])

        await waitUntil { model.state == .ready([]) }
        XCTAssertEqual(preferences.ollamaModelID, llama.id)
    }

    func testStaleCancelledRefreshCannotOverwriteNewerStateOrSelection() async {
        let client = SettingsOllamaClientSpy([
            .suspended(1),
            .models([llama]),
        ])
        let (preferences, cleanup) = makePreferences()
        defer { cleanup() }
        preferences.ollamaModelID = qwen.id
        let model = OllamaSettingsModel(
            client: client,
            preferences: preferences
        )

        model.refresh(selectedModelID: qwen.id)
        await client.waitForCallCount(1)

        preferences.ollamaModelID = llama.id
        model.refresh(selectedModelID: llama.id)
        await client.waitForCallCount(2)
        await waitUntil { model.state == .ready([self.llama]) }

        await client.resume(1, returning: [])
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(model.state, .ready([llama]))
        XCTAssertEqual(preferences.ollamaModelID, llama.id)
    }

    func testKnownErrorsUseBoundedMessagesAndUnknownErrorsAreGeneric() async {
        let secret = "synthetic-response-body-secret"
        let client = SettingsOllamaClientSpy([
            .timedOut,
            .rawFailure(secret),
        ])
        let (preferences, cleanup) = makePreferences()
        defer { cleanup() }
        let model = OllamaSettingsModel(
            client: client,
            preferences: preferences
        )

        model.refresh(selectedModelID: "")
        await waitUntil {
            model.state == .failed("The local model took too long to respond.")
        }

        model.refresh(selectedModelID: "")
        await waitUntil {
            if case .failed = model.state { return true }
            return false
        }

        guard case .failed(let message) = model.state else {
            return XCTFail("Expected a bounded failure")
        }
        XCTAssertEqual(message, "Unable to check local Ollama models.")
        XCTAssertFalse(message.contains(secret))
    }

    func testStatusTextDistinguishesNoModelsFromStoppedService() {
        XCTAssertEqual(
            OllamaSettingsModel.State.ready([]).statusText,
            "No local Ollama models found"
        )
        XCTAssertEqual(
            OllamaSettingsModel.State.notRunning.statusText,
            "Ollama is not running"
        )
        XCTAssertEqual(
            OllamaSettingsModel.State.ready([qwen]).statusText,
            "Ollama is running · 1 local model"
        )
        XCTAssertEqual(
            OllamaSettingsModel.State.ready([qwen, llama]).statusText,
            "Ollama is running · 2 local models"
        )
    }

    func testOpenOllamaUsesExpectedBundleAndActivatesApplication() async throws {
        let expectedURL = URL(fileURLWithPath: "/Applications/Ollama.app")
        var lookedUpBundleID: String?
        var openedURL: URL?
        var activates: Bool?

        try await OllamaApplication.open(
            locate: { bundleID in
                lookedUpBundleID = bundleID
                return expectedURL
            },
            launch: { url, shouldActivate in
                openedURL = url
                activates = shouldActivate
            }
        )

        XCTAssertEqual(lookedUpBundleID, "com.electron.ollama")
        XCTAssertEqual(openedURL, expectedURL)
        XCTAssertEqual(activates, true)
    }

    func testOpenOllamaMissingApplicationDoesNotLaunchAnything() async {
        var didLaunch = false

        do {
            try await OllamaApplication.open(
                locate: { _ in nil },
                launch: { _, _ in didLaunch = true }
            )
            XCTFail("Expected a missing Ollama application")
        } catch {
            XCTAssertEqual(error as? LocalAIError, .ollamaNotRunning)
        }

        XCTAssertFalse(didLaunch)
    }

    private func makePreferences() -> (Preferences, () -> Void) {
        let suiteName = "OllamaSettingsModelTests.\(UUID().uuidString)"
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
