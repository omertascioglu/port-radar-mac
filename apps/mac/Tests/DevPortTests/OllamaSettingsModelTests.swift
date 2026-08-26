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

    func chatStream(
        model: String,
        messages: [OllamaChatMessage]
    ) async throws -> LocalAITextStream {
        throw LocalAIError.malformedResponse
    }

    func unload(model: String) async {}

    func callCount() -> Int { localModelCalls }

    func waitForCallCount(_ expected: Int) async {
        while localModelCalls < expected {
            await Task.yield()
        }
    }

    func resume(_ identifier: Int, returning models: [OllamaModel]) {
        continuations.removeValue(forKey: identifier)?.resume(returning: models)
    }
}

/// Hands out test leases on the fork's private service and counts releases, so
/// every refresh path can prove the service was borrowed and returned exactly
/// once. Each lease carries a distinct process identifier so a test can tell
/// which lease a client was bound to.
private actor SettingsLeaseRecorder {
    private var acquireCount = 0
    private var releaseCount = 0

    func makeLease() -> OllamaServiceLease {
        acquireCount += 1
        return OllamaServiceLease.testInstance(
            endpoint: OllamaServiceEndpoint(
                baseURL: URL(string: "http://127.0.0.1:11435")!,
                processIdentifier: Int32(acquireCount)
            ),
            onRelease: { [self] in await recordRelease() }
        )
    }

    func counts() -> (acquires: Int, releases: Int) {
        (acquireCount, releaseCount)
    }

    func waitForReleases(_ expected: Int) async {
        while releaseCount < expected {
            await Task.yield()
        }
    }

    private func recordRelease() {
        releaseCount += 1
    }
}

/// Suspends one acquisition until the test opens the gate, and ignores
/// cancellation while suspended: the lease still arrives after the refresh was
/// cancelled, which is the path that leaks a private service if the model
/// forgets to release it.
private actor SettingsAcquireGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var waitCount = 0

    func wait() async {
        waitCount += 1
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilSuspended() async {
        while waitCount == 0 {
            await Task.yield()
        }
    }

    func open() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

/// Records the lease endpoint each client was built from, synchronously, so the
/// assertion never races the refresh task.
private final class SettingsLeasedEndpointLog: @unchecked Sendable {
    private let lock = NSLock()
    private var endpoints: [OllamaServiceEndpoint] = []

    func append(_ endpoint: OllamaServiceEndpoint) {
        lock.lock()
        endpoints.append(endpoint)
        lock.unlock()
    }

    func recorded() -> [OllamaServiceEndpoint] {
        lock.lock()
        defer { lock.unlock() }
        return endpoints
    }
}

/// Serves one `/api/tags` payload so a test can exercise the real client's
/// local-model filtering through the settings model.
private struct SettingsTagsTransport: OllamaTransporting {
    let payload: String

    func request(
        path: String,
        method: String,
        body: Data?
    ) async throws -> Data {
        guard path == "/api/tags", method == "GET" else {
            throw LocalAIError.malformedResponse
        }
        return Data(payload.utf8)
    }

    func stream(
        path: String,
        method: String,
        body: Data?
    ) async throws -> AsyncThrowingStream<Data, any Error> {
        throw LocalAIError.malformedResponse
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

    func testRefreshBorrowsOneLeaseForALeaseBoundClientAndReleasesIt() async {
        let client = SettingsOllamaClientSpy([.models([qwen, llama])])
        let recorder = SettingsLeaseRecorder()
        let leased = SettingsLeasedEndpointLog()
        let (preferences, cleanup) = makePreferences()
        defer { cleanup() }
        let model = OllamaSettingsModel(
            acquireService: { await recorder.makeLease() },
            preferences: preferences,
            makeClient: { lease in
                leased.append(lease.endpoint)
                return client
            }
        )

        XCTAssertEqual(model.state, .idle)

        model.refresh(selectedModelID: "")

        XCTAssertEqual(model.state, .loading)
        await waitUntil { model.state == .ready([self.qwen, self.llama]) }
        await recorder.waitForReleases(1)

        let counts = await recorder.counts()
        let calls = await client.callCount()
        XCTAssertEqual(counts.acquires, 1)
        XCTAssertEqual(counts.releases, 1)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(
            leased.recorded().map(\.processIdentifier),
            [1]
        )
    }

    func testStoppedServiceIsNotRunningAndStillReleasesTheLease() async {
        let client = SettingsOllamaClientSpy([.notRunning])
        let recorder = SettingsLeaseRecorder()
        let (preferences, cleanup) = makePreferences()
        defer { cleanup() }
        let model = makeModel(
            client: client,
            recorder: recorder,
            preferences: preferences
        )

        model.refresh(selectedModelID: "")

        await waitUntil { model.state == .notRunning }
        await recorder.waitForReleases(1)

        let counts = await recorder.counts()
        XCTAssertEqual(counts.acquires, 1)
        XCTAssertEqual(counts.releases, 1)
    }

    func testRunningServiceWithNoModelsGuidesInstallingOneElsewhere() async {
        let client = SettingsOllamaClientSpy([.models([])])
        let recorder = SettingsLeaseRecorder()
        let (preferences, cleanup) = makePreferences()
        defer { cleanup() }
        let model = makeModel(
            client: client,
            recorder: recorder,
            preferences: preferences
        )

        model.refresh(selectedModelID: "")

        await waitUntil { model.state == .ready([]) }
        await recorder.waitForReleases(1)

        XCTAssertNotEqual(model.state, .notRunning)
        guard let guidance = model.state.installationGuidance else {
            return XCTFail("Expected installation guidance for no models")
        }
        XCTAssertEqual(
            guidance,
            "Install a local model with Ollama outside Port Radar Offline, "
                + "then check again."
        )
        XCTAssertFalse(guidance.lowercased().contains("http"))
        XCTAssertFalse(guidance.contains("Download"))

        let counts = await recorder.counts()
        XCTAssertEqual(counts.releases, 1)
    }

    func testMissingOllamaReportsNotInstalledWithoutAnyDownloadState() async {
        let client = SettingsOllamaClientSpy([.models([qwen])])
        let recorder = SettingsLeaseRecorder()
        let (preferences, cleanup) = makePreferences()
        defer { cleanup() }
        let model = OllamaSettingsModel(
            acquireService: { throw LocalAIError.ollamaNotInstalled },
            preferences: preferences,
            makeClient: { _ in client }
        )

        model.refresh(selectedModelID: "")

        await waitUntil {
            if case .failed = model.state { return true }
            return false
        }

        guard case .failed(let message) = model.state else {
            return XCTFail("Expected a bounded failure")
        }
        XCTAssertEqual(
            message,
            "Ollama is not installed. Install it separately, then try again."
        )
        XCTAssertTrue(message.hasPrefix("Ollama is not installed."))
        XCTAssertFalse(message.lowercased().contains("http"))
        XCTAssertFalse(message.contains("Download"))
        XCTAssertNil(model.state.installationGuidance)

        let calls = await client.callCount()
        XCTAssertEqual(calls, 0)
        let counts = await recorder.counts()
        XCTAssertEqual(counts.acquires, 0)
        XCTAssertEqual(counts.releases, 0)
    }

    func testUnavailablePrivateServiceReportsBoundedFailureWithoutALease() async {
        let client = SettingsOllamaClientSpy([])
        let recorder = SettingsLeaseRecorder()
        let (preferences, cleanup) = makePreferences()
        defer { cleanup() }
        let model = OllamaSettingsModel(
            acquireService: {
                throw LocalAIError.ollamaPrivateServiceUnavailable
            },
            preferences: preferences,
            makeClient: { _ in client }
        )

        model.refresh(selectedModelID: "")

        await waitUntil {
            model.state
                == .failed("Unable to start the private local Ollama service.")
        }

        let calls = await client.callCount()
        XCTAssertEqual(calls, 0)
        let counts = await recorder.counts()
        XCTAssertEqual(counts.acquires, 0)
        XCTAssertEqual(counts.releases, 0)
    }

    func testLeaseArrivingAfterCancellationIsReleasedWithoutListingModels() async {
        let client = SettingsOllamaClientSpy([.models([qwen])])
        let recorder = SettingsLeaseRecorder()
        let gate = SettingsAcquireGate()
        let (preferences, cleanup) = makePreferences()
        defer { cleanup() }
        let model = OllamaSettingsModel(
            acquireService: {
                await gate.wait()
                return await recorder.makeLease()
            },
            preferences: preferences,
            makeClient: { _ in client }
        )

        model.refresh(selectedModelID: "")
        await gate.waitUntilSuspended()
        model.cancelRefresh()
        model.cancelRefresh()
        await gate.open()
        await recorder.waitForReleases(1)
        for _ in 0..<50 { await Task.yield() }

        let counts = await recorder.counts()
        let calls = await client.callCount()
        XCTAssertEqual(counts.acquires, 1)
        XCTAssertEqual(counts.releases, 1)
        XCTAssertEqual(calls, 0)
        XCTAssertNotEqual(model.state, .ready([qwen]))
    }

    func testDisappearanceDuringListingReleasesTheLeaseExactlyOnce() async {
        let client = SettingsOllamaClientSpy([.suspended(1)])
        let recorder = SettingsLeaseRecorder()
        let (preferences, cleanup) = makePreferences()
        defer { cleanup() }
        preferences.ollamaModelID = qwen.id
        let model = makeModel(
            client: client,
            recorder: recorder,
            preferences: preferences
        )

        model.refresh(selectedModelID: qwen.id)
        await client.waitForCallCount(1)

        // The Ollama controls disappear, twice for good measure.
        model.cancelRefresh()
        model.cancelRefresh()
        await client.resume(1, returning: [])
        await recorder.waitForReleases(1)
        for _ in 0..<50 { await Task.yield() }

        let counts = await recorder.counts()
        XCTAssertEqual(counts.acquires, 1)
        XCTAssertEqual(counts.releases, 1)
        XCTAssertNotEqual(model.state, .ready([]))
        XCTAssertEqual(preferences.ollamaModelID, qwen.id)

        // A cancelled check leaves the control usable again instead of a
        // permanently spinning row.
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.state.checkButtonTitle, "Check local models")
    }

    func testConcurrentRefreshCancelsTheOldOperationAndReleasesEveryLease() async {
        let client = SettingsOllamaClientSpy([
            .suspended(1),
            .models([llama]),
        ])
        let recorder = SettingsLeaseRecorder()
        let leased = SettingsLeasedEndpointLog()
        let (preferences, cleanup) = makePreferences()
        defer { cleanup() }
        preferences.ollamaModelID = qwen.id
        let model = OllamaSettingsModel(
            acquireService: { await recorder.makeLease() },
            preferences: preferences,
            makeClient: { lease in
                leased.append(lease.endpoint)
                return client
            }
        )

        model.refresh(selectedModelID: qwen.id)
        await client.waitForCallCount(1)

        preferences.ollamaModelID = llama.id
        model.refresh(selectedModelID: llama.id)
        await client.waitForCallCount(2)
        await waitUntil { model.state == .ready([self.llama]) }

        await client.resume(1, returning: [])
        await recorder.waitForReleases(2)
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(model.state, .ready([llama]))
        XCTAssertEqual(preferences.ollamaModelID, llama.id)
        let counts = await recorder.counts()
        XCTAssertEqual(counts.acquires, 2)
        XCTAssertEqual(counts.releases, 2)
        XCTAssertEqual(
            leased.recorded().map(\.processIdentifier),
            [1, 2]
        )
    }

    func testDisappearedSelectionIsCleared() async {
        let client = SettingsOllamaClientSpy([.models([llama])])
        let recorder = SettingsLeaseRecorder()
        let (preferences, cleanup) = makePreferences()
        defer { cleanup() }
        preferences.ollamaModelID = qwen.id
        let model = makeModel(
            client: client,
            recorder: recorder,
            preferences: preferences
        )

        model.refresh(selectedModelID: qwen.id)

        await waitUntil { model.state == .ready([self.llama]) }
        XCTAssertEqual(preferences.ollamaModelID, "")
        await recorder.waitForReleases(1)
    }

    func testSelectionChangedDuringRefreshIsNotCleared() async {
        let client = SettingsOllamaClientSpy([.suspended(1)])
        let recorder = SettingsLeaseRecorder()
        let (preferences, cleanup) = makePreferences()
        defer { cleanup() }
        preferences.ollamaModelID = qwen.id
        let model = makeModel(
            client: client,
            recorder: recorder,
            preferences: preferences
        )

        model.refresh(selectedModelID: qwen.id)
        await client.waitForCallCount(1)
        preferences.ollamaModelID = llama.id
        await client.resume(1, returning: [])

        await waitUntil { model.state == .ready([]) }
        XCTAssertEqual(preferences.ollamaModelID, llama.id)
        await recorder.waitForReleases(1)
    }

    func testKnownErrorsUseBoundedMessagesAndUnknownErrorsAreGeneric() async {
        let secret = "synthetic-response-body-secret"
        let client = SettingsOllamaClientSpy([
            .timedOut,
            .rawFailure(secret),
        ])
        let recorder = SettingsLeaseRecorder()
        let (preferences, cleanup) = makePreferences()
        defer { cleanup() }
        let model = makeModel(
            client: client,
            recorder: recorder,
            preferences: preferences
        )

        model.refresh(selectedModelID: "")
        await waitUntil {
            model.state == .failed("The local model took too long to respond.")
        }

        model.refresh(selectedModelID: "")
        await waitUntil {
            model.state == .failed("Unable to check local Ollama models.")
        }

        guard case .failed(let message) = model.state else {
            return XCTFail("Expected a bounded failure")
        }
        XCTAssertEqual(message, "Unable to check local Ollama models.")
        XCTAssertFalse(message.contains(secret))

        await recorder.waitForReleases(2)
        let counts = await recorder.counts()
        XCTAssertEqual(counts.acquires, 2)
        XCTAssertEqual(counts.releases, 2)
    }

    func testCloudAndAmbiguousModelsNeverReachThePicker() async {
        let payload = """
        {
          "models": [
            {
              "name": "qwen3:4b",
              "model": "qwen3:4b",
              "size": 2500000000,
              "digest": "sha256:local",
              "details": { "format": "gguf" }
            },
            {
              "name": "gpt-oss:120b-cloud",
              "model": "gpt-oss:120b-cloud",
              "size": 1024,
              "digest": "sha256:cloud",
              "details": { "format": "gguf" }
            },
            {
              "name": "hosted:8b",
              "model": "hosted:8b",
              "remote_host": "https://example.invalid",
              "size": 1024,
              "digest": "sha256:remote",
              "details": { "format": "gguf" }
            },
            {
              "name": "ambiguous:8b",
              "model": "ambiguous:8b",
              "size": 0,
              "digest": "",
              "details": { "format": "" }
            }
          ]
        }
        """
        let recorder = SettingsLeaseRecorder()
        let (preferences, cleanup) = makePreferences()
        defer { cleanup() }
        let model = OllamaSettingsModel(
            acquireService: { await recorder.makeLease() },
            preferences: preferences,
            makeClient: { _ in
                OllamaClient(
                    transport: SettingsTagsTransport(payload: payload)
                )
            }
        )

        model.refresh(selectedModelID: "")

        await waitUntil { model.state == .ready([self.qwen]) }
        XCTAssertEqual(model.state, .ready([qwen]))
        await recorder.waitForReleases(1)
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

    private func makeModel(
        client: any OllamaClientProtocol,
        recorder: SettingsLeaseRecorder,
        preferences: Preferences
    ) -> OllamaSettingsModel {
        OllamaSettingsModel(
            acquireService: { await recorder.makeLease() },
            preferences: preferences,
            makeClient: { _ in client }
        )
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
