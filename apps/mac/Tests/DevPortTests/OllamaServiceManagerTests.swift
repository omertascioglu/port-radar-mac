// Modification notice: Added in 2026 for the Port Radar Offline fork.
import Foundation
import XCTest
@testable import DevPort

private enum ServiceTestError: Error, Sendable {
    case probeFailed
}

private actor ServiceOwnedProcessFake: OllamaOwnedProcess {
    let processIdentifier: Int32
    private var running = true

    init(processIdentifier: Int32) {
        self.processIdentifier = processIdentifier
    }

    var isRunning: Bool { running }

    func terminate() {
        running = false
    }

    func waitForExit() async {}

    func forceKill() {
        running = false
    }

    func simulateExit() {
        running = false
    }
}

/// Owned-process fake whose `isRunning` check can be parked, so a final
/// `release()` can interleave with an `acquire()` that is already suspended
/// inside its liveness check. `terminate()` only records the request: a real
/// child still reports as running inside its stop grace period, which is the
/// exact window where the resumed `acquire()` must re-validate actor state.
private actor ParkedLivenessProcessFake: OllamaOwnedProcess {
    let processIdentifier: Int32
    private var shouldParkNextCall = false
    private var didPark = false
    private var parkedCallers: [CheckedContinuation<Void, Never>] = []
    private var parkObservers: [CheckedContinuation<Void, Never>] = []
    private var terminationRequested = false

    init(processIdentifier: Int32) {
        self.processIdentifier = processIdentifier
    }

    var isRunning: Bool {
        get async {
            if shouldParkNextCall {
                shouldParkNextCall = false
                didPark = true
                let observers = parkObservers
                parkObservers.removeAll()
                observers.forEach { $0.resume() }
                await withCheckedContinuation { continuation in
                    parkedCallers.append(continuation)
                }
            }
            return true
        }
    }

    func terminate() {
        terminationRequested = true
    }

    func waitForExit() async {}

    func forceKill() {
        terminationRequested = true
    }

    func didRequestTermination() -> Bool { terminationRequested }

    func parkNextLivenessCheck() {
        shouldParkNextCall = true
    }

    func waitForParkedLivenessCheck() async {
        if didPark { return }
        await withCheckedContinuation { continuation in
            parkObservers.append(continuation)
        }
    }

    func resumeParkedLivenessCheck() {
        let parked = parkedCallers
        parkedCallers.removeAll()
        parked.forEach { $0.resume() }
    }
}

private actor ServiceProcessControllerFake: OllamaServiceProcessControlling {
    struct Snapshot: Equatable, Sendable {
        let startCount: Int
        let stopCount: Int
        let events: [String]
    }

    private var queuedProcesses: [any OllamaOwnedProcess]
    private var currentProcess: (any OllamaOwnedProcess)?
    private var startCount = 0
    private var stopCount = 0
    private var events: [String] = []
    private var shouldBlockStop = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopStartedWaiters: [CheckedContinuation<Void, Never>] = []

    init(processes: [any OllamaOwnedProcess]) {
        queuedProcesses = processes
    }

    func start() async throws -> any OllamaOwnedProcess {
        startCount += 1
        events.append("start")
        guard !queuedProcesses.isEmpty else {
            throw LocalAIError.ollamaPrivateServiceUnavailable
        }
        let process = queuedProcesses.removeFirst()
        currentProcess = process
        return process
    }

    func stop() async {
        stopCount += 1
        events.append("stop-began")
        let started = stopStartedWaiters
        stopStartedWaiters.removeAll()
        started.forEach { $0.resume() }
        if shouldBlockStop {
            await withCheckedContinuation { continuation in
                stopWaiters.append(continuation)
            }
        }
        await currentProcess?.terminate()
        currentProcess = nil
        events.append("stop-ended")
    }

    func blockStop() {
        shouldBlockStop = true
    }

    func waitForStopToBegin() async {
        if stopCount > 0 { return }
        await withCheckedContinuation { continuation in
            stopStartedWaiters.append(continuation)
        }
    }

    func resumeStop() {
        shouldBlockStop = false
        let pending = stopWaiters
        stopWaiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func snapshot() -> Snapshot {
        Snapshot(startCount: startCount, stopCount: stopCount, events: events)
    }
}

private struct ServicePortCheckerStub: OllamaServicePortChecking {
    let isAvailable: Bool

    func isAvailable(host: String, port: Int) -> Bool {
        isAvailable && host == "127.0.0.1" && port == 11435
    }
}

private actor ServiceProbeFake: OllamaServiceReadinessProbing {
    private var results: [Result<OllamaReadinessResponse, Error>]
    private var requests: [URL] = []
    private var shouldBlock = false
    private var probeWaiters: [CheckedContinuation<Void, Never>] = []
    private var probeStartedWaiters: [CheckedContinuation<Void, Never>] = []

    init(results: [Result<OllamaReadinessResponse, Error>]) {
        self.results = results
    }

    func probe(_ url: URL) async throws -> OllamaReadinessResponse {
        requests.append(url)
        let started = probeStartedWaiters
        probeStartedWaiters.removeAll()
        started.forEach { $0.resume() }
        if shouldBlock {
            await withCheckedContinuation { continuation in
                probeWaiters.append(continuation)
            }
        }
        guard !results.isEmpty else { throw ServiceTestError.probeFailed }
        return try results.removeFirst().get()
    }

    func block() {
        shouldBlock = true
    }

    func waitForProbeToBegin() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { continuation in
            probeStartedWaiters.append(continuation)
        }
    }

    func resume() {
        shouldBlock = false
        let pending = probeWaiters
        probeWaiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func recordedRequests() -> [URL] { requests }
}

private actor CancellationProbeFake: OllamaServiceReadinessProbing {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func probe(_ url: URL) async throws -> OllamaReadinessResponse {
        started = true
        let pending = startWaiters
        startWaiters.removeAll()
        pending.forEach { $0.resume() }
        try await Task.sleep(for: .seconds(60))
        throw ServiceTestError.probeFailed
    }

    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }
}

private actor ExitDuringSuccessfulProbeFake: OllamaServiceReadinessProbing {
    struct Snapshot: Equatable, Sendable {
        let requests: [URL]
        let childWasRunningBeforeProbeResult: Bool
    }

    private let process: ServiceOwnedProcessFake
    private let response: OllamaReadinessResponse
    private var requests: [URL] = []
    private var childWasRunningBeforeProbeResult = false

    init(
        process: ServiceOwnedProcessFake,
        response: OllamaReadinessResponse
    ) {
        self.process = process
        self.response = response
    }

    func probe(_ url: URL) async throws -> OllamaReadinessResponse {
        requests.append(url)
        childWasRunningBeforeProbeResult = await process.isRunning
        await process.simulateExit()
        return response
    }

    func snapshot() -> Snapshot {
        Snapshot(
            requests: requests,
            childWasRunningBeforeProbeResult: childWasRunningBeforeProbeResult
        )
    }
}

private actor ServiceSleepRecorder {
    private var durations: [Duration] = []

    func sleep(_ duration: Duration) async throws {
        durations.append(duration)
        try Task.checkCancellation()
    }

    func snapshot() -> [Duration] { durations }
}

final class OllamaServiceManagerTests: XCTestCase {
    private let endpointURL = URL(string: "http://127.0.0.1:11435")!
    private let versionURL = URL(string: "http://127.0.0.1:11435/api/version")!

    func testFirstAcquireStartsOnceAndReturnsExactOwnedEndpoint() async throws {
        let process = ServiceOwnedProcessFake(processIdentifier: 4101)
        let controller = ServiceProcessControllerFake(processes: [process])
        let probe = ServiceProbeFake(results: [.success(readyResponse())])
        let manager = makeManager(controller: controller, probe: probe)

        let lease = try await manager.acquire()

        XCTAssertEqual(
            lease.endpoint,
            OllamaServiceEndpoint(baseURL: endpointURL, processIdentifier: 4101)
        )
        let controllerSnapshot = await controller.snapshot()
        let requests = await probe.recordedRequests()
        XCTAssertEqual(controllerSnapshot.startCount, 1)
        XCTAssertEqual(requests, [versionURL])

        await lease.release()
    }

    func testConcurrentAcquiresShareStartupAndReferenceCountedLifetime() async throws {
        let process = ServiceOwnedProcessFake(processIdentifier: 4102)
        let controller = ServiceProcessControllerFake(processes: [process])
        let probe = ServiceProbeFake(results: [.success(readyResponse())])
        await probe.block()
        let manager = makeManager(controller: controller, probe: probe)

        let firstTask = Task { try await manager.acquire() }
        await probe.waitForProbeToBegin()
        let secondTask = Task { try await manager.acquire() }
        await Task.yield()
        await probe.resume()

        let first = try await firstTask.value
        let second = try await secondTask.value
        XCTAssertEqual(first.endpoint, second.endpoint)
        var snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.startCount, 1)

        await first.release()
        snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.stopCount, 0)

        await second.release()
        snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.stopCount, 1)
    }

    func testReadinessRetriesExactVersionURLAndConfirmsChildStillRuns() async throws {
        let process = ServiceOwnedProcessFake(processIdentifier: 4103)
        let controller = ServiceProcessControllerFake(processes: [process])
        let probe = ServiceProbeFake(results: [
            .failure(ServiceTestError.probeFailed),
            .success(readyResponse()),
        ])
        let sleep = ServiceSleepRecorder()
        let manager = makeManager(
            controller: controller,
            probe: probe,
            sleep: { duration in try await sleep.sleep(duration) }
        )

        let lease = try await manager.acquire()

        let requests = await probe.recordedRequests()
        let sleeps = await sleep.snapshot()
        XCTAssertEqual(requests, [versionURL, versionURL])
        XCTAssertEqual(sleeps, [.milliseconds(10)])
        let processIsRunning = await process.isRunning
        XCTAssertTrue(processIsRunning)
        await lease.release()
    }

    func testSuccessfulProbeCannotMakeExitedChildReady() async {
        let process = ServiceOwnedProcessFake(processIdentifier: 4116)
        let controller = ServiceProcessControllerFake(processes: [process])
        let probe = ExitDuringSuccessfulProbeFake(
            process: process,
            response: readyResponse()
        )
        let manager = makeManager(controller: controller, probe: probe)

        await assertPrivateServiceFailure { _ = try await manager.acquire() }

        let probeSnapshot = await probe.snapshot()
        let controllerSnapshot = await controller.snapshot()
        XCTAssertEqual(probeSnapshot.requests, [versionURL])
        XCTAssertTrue(probeSnapshot.childWasRunningBeforeProbeResult)
        XCTAssertEqual(controllerSnapshot.startCount, 1)
        XCTAssertEqual(controllerSnapshot.stopCount, 1)
        let processIsRunning = await process.isRunning
        XCTAssertFalse(processIsRunning)
    }

    func testLaterAcquireNeverReturnsEndpointForExitedOwnedChild() async throws {
        let process = ServiceOwnedProcessFake(processIdentifier: 4115)
        let controller = ServiceProcessControllerFake(processes: [process])
        let probe = ServiceProbeFake(results: [.success(readyResponse())])
        let manager = makeManager(controller: controller, probe: probe)
        let firstLease = try await manager.acquire()
        await process.simulateExit()

        await assertPrivateServiceFailure { _ = try await manager.acquire() }

        let snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.startCount, 1)
        XCTAssertEqual(snapshot.stopCount, 1)
        await firstLease.release()
    }

    func testOccupiedDedicatedPortFailsWithoutLaunchingOrStoppingAnything() async {
        let unrelated = ServiceOwnedProcessFake(processIdentifier: 9999)
        let controller = ServiceProcessControllerFake(processes: [unrelated])
        let probe = ServiceProbeFake(results: [.success(readyResponse())])
        let manager = makeManager(
            controller: controller,
            portAvailable: false,
            probe: probe
        )

        await assertPrivateServiceFailure { _ = try await manager.acquire() }

        let snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.startCount, 0)
        XCTAssertEqual(snapshot.stopCount, 0)
        let unrelatedIsRunning = await unrelated.isRunning
        XCTAssertTrue(unrelatedIsRunning)
    }

    func testEarlyChildExitFailsClosedAndStopsOnlyOwnedChild() async {
        let process = ServiceOwnedProcessFake(processIdentifier: 4104)
        await process.simulateExit()
        let controller = ServiceProcessControllerFake(processes: [process])
        let probe = ServiceProbeFake(results: [.success(readyResponse())])
        let manager = makeManager(controller: controller, probe: probe)

        await assertPrivateServiceFailure { _ = try await manager.acquire() }

        let snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.startCount, 1)
        XCTAssertEqual(snapshot.stopCount, 1)
        let requests = await probe.recordedRequests()
        XCTAssertEqual(requests, [])
    }

    func testWrongFinalURLFailsClosedAndStopsOwnedChild() async {
        let process = ServiceOwnedProcessFake(processIdentifier: 4105)
        let controller = ServiceProcessControllerFake(processes: [process])
        let probe = ServiceProbeFake(results: [
            .success(
                OllamaReadinessResponse(
                    finalURL: URL(string: "https://example.invalid/api/version")!,
                    statusCode: 200,
                    hasVersion: true
                )
            )
        ])
        let manager = makeManager(controller: controller, probe: probe)

        await assertPrivateServiceFailure { _ = try await manager.acquire() }

        let snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.stopCount, 1)
    }

    func testUnrecognizedAndFailedProbesExhaustBoundAndStopOwnedChild() async {
        let process = ServiceOwnedProcessFake(processIdentifier: 4106)
        let controller = ServiceProcessControllerFake(processes: [process])
        let probe = ServiceProbeFake(results: [
            .success(
                OllamaReadinessResponse(
                    finalURL: versionURL,
                    statusCode: 503,
                    hasVersion: false
                )
            ),
            .failure(ServiceTestError.probeFailed),
            .success(
                OllamaReadinessResponse(
                    finalURL: versionURL,
                    statusCode: 200,
                    hasVersion: false
                )
            ),
        ])
        let manager = makeManager(controller: controller, probe: probe)

        await assertPrivateServiceFailure { _ = try await manager.acquire() }

        let requests = await probe.recordedRequests()
        let snapshot = await controller.snapshot()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(snapshot.stopCount, 1)
    }

    func testCopiedLeaseRepeatedAndConcurrentReleaseStopsExactlyOnce() async throws {
        let process = ServiceOwnedProcessFake(processIdentifier: 4107)
        let controller = ServiceProcessControllerFake(processes: [process])
        let probe = ServiceProbeFake(results: [.success(readyResponse())])
        let manager = makeManager(controller: controller, probe: probe)
        let lease = try await manager.acquire()
        let copiedLease = lease

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        await lease.release()
                    } else {
                        await copiedLease.release()
                    }
                }
            }
        }

        let snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.stopCount, 1)
    }

    func testAcquireRacingFinalReleaseWaitsForStopThenStartsFreshService() async throws {
        let firstProcess = ServiceOwnedProcessFake(processIdentifier: 4108)
        let secondProcess = ServiceOwnedProcessFake(processIdentifier: 4109)
        let controller = ServiceProcessControllerFake(
            processes: [firstProcess, secondProcess]
        )
        let probe = ServiceProbeFake(results: [
            .success(readyResponse()),
            .success(readyResponse()),
        ])
        let manager = makeManager(controller: controller, probe: probe)
        let first = try await manager.acquire()
        await controller.blockStop()

        let releaseTask = Task { await first.release() }
        await controller.waitForStopToBegin()
        let acquireTask = Task { try await manager.acquire() }
        await Task.yield()

        var snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.startCount, 1)
        await controller.resumeStop()
        await releaseTask.value
        let second = try await acquireTask.value

        XCTAssertEqual(second.endpoint.processIdentifier, 4109)
        snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.startCount, 2)
        XCTAssertEqual(
            snapshot.events,
            ["start", "stop-began", "stop-ended", "start"]
        )
        await second.release()
    }

    func testFinalReleaseDuringParkedLivenessCheckNeverLeasesStoppedService() async throws {
        let firstProcess = ParkedLivenessProcessFake(processIdentifier: 4117)
        let secondProcess = ServiceOwnedProcessFake(processIdentifier: 4118)
        let controller = ServiceProcessControllerFake(
            processes: [firstProcess, secondProcess]
        )
        let probe = ServiceProbeFake(results: [
            .success(readyResponse()),
            .success(readyResponse()),
        ])
        let manager = makeManager(controller: controller, probe: probe)
        let first = try await manager.acquire()

        await firstProcess.parkNextLivenessCheck()
        let acquireTask = Task { try await manager.acquire() }
        await firstProcess.waitForParkedLivenessCheck()
        await first.release()
        var snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.events, ["start", "stop-began", "stop-ended"])
        let firstWasTerminated = await firstProcess.didRequestTermination()
        XCTAssertTrue(firstWasTerminated)
        await firstProcess.resumeParkedLivenessCheck()

        let second = try await acquireTask.value
        XCTAssertNotEqual(second.endpoint.processIdentifier, 4117)
        XCTAssertEqual(second.endpoint.processIdentifier, 4118)
        snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.startCount, 2)
        XCTAssertEqual(snapshot.stopCount, 1)

        await second.release()
        snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.stopCount, 2)
        XCTAssertEqual(
            snapshot.events,
            [
                "start", "stop-began", "stop-ended",
                "start", "stop-began", "stop-ended",
            ]
        )
        let secondIsRunning = await secondProcess.isRunning
        XCTAssertFalse(secondIsRunning)
    }

    func testCancellationDuringOnlyStartupStopsUnownedChild() async {
        let process = ServiceOwnedProcessFake(processIdentifier: 4110)
        let controller = ServiceProcessControllerFake(processes: [process])
        let probe = CancellationProbeFake()
        let manager = makeManager(controller: controller, probe: probe)

        let acquireTask = Task { try await manager.acquire() }
        await probe.waitForStart()
        acquireTask.cancel()

        do {
            _ = try await acquireTask.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.stopCount, 1)
        let processIsRunning = await process.isRunning
        XCTAssertFalse(processIsRunning)
    }

    func testCancellationOfOneWaiterDoesNotCancelSharedStartup() async throws {
        let process = ServiceOwnedProcessFake(processIdentifier: 4111)
        let controller = ServiceProcessControllerFake(processes: [process])
        let probe = ServiceProbeFake(results: [.success(readyResponse())])
        await probe.block()
        let manager = makeManager(controller: controller, probe: probe)

        let canceledTask = Task { try await manager.acquire() }
        await probe.waitForProbeToBegin()
        let survivingTask = Task { try await manager.acquire() }
        await waitForPendingAcquireCount(2, manager: manager)
        canceledTask.cancel()
        await probe.resume()

        do {
            _ = try await canceledTask.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let survivingLease = try await survivingTask.value
        var snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.startCount, 1)
        XCTAssertEqual(snapshot.stopCount, 0)

        await survivingLease.release()
        snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.stopCount, 1)
    }

    func testManyConcurrentWaitersResumeWithOneSharedEndpoint() async throws {
        let process = ServiceOwnedProcessFake(processIdentifier: 4112)
        let controller = ServiceProcessControllerFake(processes: [process])
        let probe = ServiceProbeFake(results: [.success(readyResponse())])
        await probe.block()
        let manager = makeManager(controller: controller, probe: probe)

        let tasks = (0..<24).map { _ in
            Task { try await manager.acquire() }
        }
        await probe.waitForProbeToBegin()
        await probe.resume()
        var leases: [OllamaServiceLease] = []
        for task in tasks {
            leases.append(try await task.value)
        }

        XCTAssertEqual(Set(leases.map(\.endpoint.processIdentifier)), [4112])
        var snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.startCount, 1)
        for lease in leases { await lease.release() }
        snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.stopCount, 1)
    }

    func testShutdownAllStopsOwnedServiceAndPermanentlyRejectsAcquisition() async throws {
        let process = ServiceOwnedProcessFake(processIdentifier: 4113)
        let controller = ServiceProcessControllerFake(processes: [process])
        let probe = ServiceProbeFake(results: [.success(readyResponse())])
        let manager = makeManager(controller: controller, probe: probe)
        let lease = try await manager.acquire()

        await manager.shutdownAll()
        await assertPrivateServiceFailure { _ = try await manager.acquire() }
        await lease.release()

        let snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.startCount, 1)
        XCTAssertEqual(snapshot.stopCount, 1)
    }

    func testShutdownDuringStartupCancelsAndStopsOnlyOwnedChild() async {
        let process = ServiceOwnedProcessFake(processIdentifier: 4114)
        let unrelated = ServiceOwnedProcessFake(processIdentifier: 9998)
        let controller = ServiceProcessControllerFake(processes: [process])
        let probe = CancellationProbeFake()
        let manager = makeManager(controller: controller, probe: probe)

        let acquireTask = Task { try await manager.acquire() }
        await probe.waitForStart()
        await manager.shutdownAll()

        await assertPrivateServiceFailure { _ = try await acquireTask.value }
        let snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.stopCount, 1)
        let processIsRunning = await process.isRunning
        let unrelatedIsRunning = await unrelated.isRunning
        XCTAssertFalse(processIsRunning)
        XCTAssertTrue(unrelatedIsRunning)
    }

    private func makeManager(
        controller: ServiceProcessControllerFake,
        portAvailable: Bool = true,
        probe: any OllamaServiceReadinessProbing,
        sleep: @escaping OllamaServiceManager.Sleep = { _ in
            try Task.checkCancellation()
        }
    ) -> OllamaServiceManager {
        OllamaServiceManager(
            processController: controller,
            portChecker: ServicePortCheckerStub(isAvailable: portAvailable),
            readinessProbe: probe,
            sleep: sleep,
            readinessAttempts: 3,
            readinessInterval: .milliseconds(10)
        )
    }

    private func readyResponse() -> OllamaReadinessResponse {
        OllamaReadinessResponse(
            finalURL: versionURL,
            statusCode: 200,
            hasVersion: true
        )
    }

    private func assertPrivateServiceFailure(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected private service failure", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? LocalAIError,
                .ollamaPrivateServiceUnavailable,
                file: file,
                line: line
            )
            let description = (error as? LocalAIError)?.errorDescription ?? ""
            XCTAssertEqual(
                description,
                "Unable to start the private local Ollama service.",
                file: file,
                line: line
            )
            XCTAssertLessThan(description.count, 100, file: file, line: line)
        }
    }

    private func waitForPendingAcquireCount(
        _ expectedCount: Int,
        manager: OllamaServiceManager,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if await manager.pendingAcquireCountForTesting() == expectedCount {
                return
            }
            await Task.yield()
        }
        XCTFail(
            "Timed out waiting for \(expectedCount) pending acquires",
            file: file,
            line: line
        )
    }
}
