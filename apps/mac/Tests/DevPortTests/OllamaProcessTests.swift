// Modification notice: Added in 2026 for the Port Radar Offline fork.
import Foundation
import XCTest
@testable import DevPort

private enum ProcessTestError: Error {
    case launchFailed
}

private struct ProcessLocatorStub: OllamaExecutableLocating {
    let result: Result<URL, Error>

    func locate() throws -> URL {
        try result.get()
    }
}

private final class ProcessLauncherSpy: OllamaProcessLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<any OllamaOwnedProcess, Error>
    private var storedSpecs: [OllamaLaunchSpec] = []

    init(result: Result<any OllamaOwnedProcess, Error>) {
        self.result = result
    }

    var specs: [OllamaLaunchSpec] {
        lock.withLock { storedSpecs }
    }

    func launch(_ spec: OllamaLaunchSpec) throws -> any OllamaOwnedProcess {
        lock.withLock { storedSpecs.append(spec) }
        return try result.get()
    }
}

private actor OwnedProcessFake: OllamaOwnedProcess {
    enum TerminationBehavior: Sendable {
        case exits
        case staysRunning
    }

    let processIdentifier: Int32
    private let terminationBehavior: TerminationBehavior
    private var running = true
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var terminateCount = 0
    private(set) var forceKillCount = 0
    private(set) var forceKilledPIDs: [Int32] = []
    private(set) var waitForExitCount = 0

    struct Snapshot: Equatable, Sendable {
        let isRunning: Bool
        let terminateCount: Int
        let forceKillCount: Int
        let forceKilledPIDs: [Int32]
    }

    init(
        processIdentifier: Int32 = 4242,
        terminationBehavior: TerminationBehavior
    ) {
        self.processIdentifier = processIdentifier
        self.terminationBehavior = terminationBehavior
    }

    var isRunning: Bool { running }

    func terminate() {
        terminateCount += 1
        if terminationBehavior == .exits {
            finish()
        }
    }

    func waitForExit() async {
        waitForExitCount += 1
        guard running else { return }
        await withCheckedContinuation { continuation in
            exitWaiters.append(continuation)
        }
    }

    func forceKill() {
        forceKillCount += 1
        forceKilledPIDs.append(processIdentifier)
        finish()
    }

    func simulateExit() {
        finish()
    }

    func snapshot() -> Snapshot {
        Snapshot(
            isRunning: running,
            terminateCount: terminateCount,
            forceKillCount: forceKillCount,
            forceKilledPIDs: forceKilledPIDs
        )
    }

    private func finish() {
        guard running else { return }
        running = false
        let waiters = exitWaiters
        exitWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor ProcessSleepGate {
    private var calls: [Duration] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var callWaiters: [CheckedContinuation<Void, Never>] = []

    func sleep(_ duration: Duration) async {
        calls.append(duration)
        let pending = callWaiters
        callWaiters.removeAll()
        pending.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitForCall() async {
        guard calls.isEmpty else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append(continuation)
        }
    }

    func resumeAll() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func recordedCalls() -> [Duration] { calls }
}

final class OllamaProcessTests: XCTestCase {
    private let executableURL = URL(
        fileURLWithPath: "/Applications/Ollama.app/Contents/Resources/ollama"
    )

    func testStartLaunchesCanonicalExecutableWithExactPrivateServiceSpec() async throws {
        let process = OwnedProcessFake(terminationBehavior: .exits)
        let launcher = ProcessLauncherSpy(result: .success(process))
        let manager = makeManager(
            launcher: launcher,
            environment: [
                "PATH": "/usr/bin:/bin",
                "HOME": "/Users/example",
                "TMPDIR": "/private/tmp/example/",
                "LANG": "en_US.UTF-8",
                "LC_ALL": "C",
                "LC_CTYPE": "UTF-8",
                "OLLAMA_MODELS": "/Users/example/.ollama/models",
            ]
        )

        try await manager.start()

        XCTAssertEqual(
            launcher.specs,
            [
                OllamaLaunchSpec(
                    executableURL: executableURL,
                    arguments: ["serve"],
                    environment: [
                        "PATH": "/usr/bin:/bin",
                        "HOME": "/Users/example",
                        "TMPDIR": "/private/tmp/example/",
                        "LANG": "en_US.UTF-8",
                        "LC_ALL": "C",
                        "LC_CTYPE": "UTF-8",
                        "OLLAMA_MODELS": "/Users/example/.ollama/models",
                        "OLLAMA_HOST": "127.0.0.1:11435",
                        "OLLAMA_NO_CLOUD": "1",
                    ],
                    host: "127.0.0.1",
                    port: 11435
                )
            ]
        )
    }

    func testStartStripsProxyCredentialsSecretsAndUnrelatedEnvironment() async throws {
        let process = OwnedProcessFake(terminationBehavior: .exits)
        let launcher = ProcessLauncherSpy(result: .success(process))
        var environment = [
            "PATH": "/usr/bin",
            "OLLAMA_HOST": "evil.example:443",
            "OLLAMA_NO_CLOUD": "0",
            "OLLAMA_API_KEY": "api-secret",
            "AUTH_TOKEN": "auth-secret",
            "SERVICE_SECRET": "service-secret",
            "UNRELATED_VALUE": "must-not-pass",
        ]
        for key in [
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
            "http_proxy", "https_proxy", "all_proxy", "no_proxy",
            "Http_Proxy", "Https_Proxy", "All_Proxy", "No_Proxy",
            "hTtP_pRoXy", "hTtPs_PrOxY", "aLl_PrOxY", "nO_pRoXy",
        ] {
            environment[key] = "http://proxy.invalid"
        }
        environment["Ollama_Api_Key"] = "mixed-case-api-secret"
        environment["authorization"] = "authorization-secret"
        environment["ACCESS_TOKEN"] = "access-secret"
        let manager = makeManager(launcher: launcher, environment: environment)

        try await manager.start()

        XCTAssertEqual(
            launcher.specs.first?.environment,
            [
                "PATH": "/usr/bin",
                "OLLAMA_HOST": "127.0.0.1:11435",
                "OLLAMA_NO_CLOUD": "1",
            ]
        )
    }

    func testMissingExecutableMapsToBoundedInstallMessageWithoutLaunching() async {
        let process = OwnedProcessFake(terminationBehavior: .exits)
        let launcher = ProcessLauncherSpy(result: .success(process))
        let manager = OllamaProcessManager(
            locator: ProcessLocatorStub(result: .failure(OllamaExecutableLocatorError.notInstalled)),
            launcher: launcher,
            parentEnvironment: { [:] }
        )

        do {
            try await manager.start()
            XCTFail("Expected Ollama installation error")
        } catch {
            XCTAssertEqual(error as? LocalAIError, .ollamaNotInstalled)
            XCTAssertEqual(
                (error as? LocalAIError)?.errorDescription,
                "Ollama is not installed. Install it separately, then try again."
            )
        }
        XCTAssertTrue(launcher.specs.isEmpty)
    }

    func testLaunchFailureMapsToBoundedGenericMessage() async {
        let launcher = ProcessLauncherSpy(
            result: .failure(ProcessTestError.launchFailed)
        )
        let manager = makeManager(
            launcher: launcher,
            environment: ["PRIVATE_TOKEN": "never-expose-this"]
        )

        do {
            try await manager.start()
            XCTFail("Expected private service error")
        } catch {
            XCTAssertEqual(
                error as? LocalAIError,
                .ollamaPrivateServiceUnavailable
            )
            let description = (error as? LocalAIError)?.errorDescription ?? ""
            XCTAssertEqual(
                description,
                "Unable to start the private local Ollama service."
            )
            XCTAssertFalse(description.contains("never-expose-this"))
            XCTAssertFalse(description.contains(executableURL.path))
            XCTAssertFalse(description.contains("launchFailed"))
        }
    }

    func testExitSignalRemembersExitThatHappensBeforeWaiterRegisters() async {
        let signal = OllamaProcessExitSignal()

        await signal.signalExit()
        await signal.waitForExit()

        let hasExited = await signal.hasExited
        XCTAssertTrue(hasExited)
    }

    func testStopTerminatesGracefullyWithoutForceKill() async throws {
        let process = OwnedProcessFake(terminationBehavior: .exits)
        let sleepGate = ProcessSleepGate()
        let manager = makeManager(
            process: process,
            sleep: { duration in await sleepGate.sleep(duration) }
        )
        try await manager.start()

        await manager.stop()

        let snapshot = await process.snapshot()
        XCTAssertEqual(snapshot.terminateCount, 1)
        XCTAssertEqual(snapshot.forceKillCount, 0)
        XCTAssertFalse(snapshot.isRunning)
    }

    func testStopObservesAsynchronousExitBeforeGraceExpires() async throws {
        let process = OwnedProcessFake(terminationBehavior: .staysRunning)
        let sleepGate = ProcessSleepGate()
        let manager = makeManager(
            process: process,
            sleep: { duration in await sleepGate.sleep(duration) }
        )
        try await manager.start()

        let stopTask = Task { await manager.stop() }
        await sleepGate.waitForCall()
        await process.simulateExit()
        await stopTask.value
        await sleepGate.resumeAll()

        let snapshot = await process.snapshot()
        XCTAssertEqual(snapshot.terminateCount, 1)
        XCTAssertEqual(snapshot.forceKillCount, 0)
        XCTAssertFalse(snapshot.isRunning)
    }

    func testStopForceKillsExactOwnedPIDAfterBoundedGrace() async throws {
        let process = OwnedProcessFake(
            processIdentifier: 7331,
            terminationBehavior: .staysRunning
        )
        let sleepGate = ProcessSleepGate()
        let manager = makeManager(
            process: process,
            sleep: { duration in await sleepGate.sleep(duration) }
        )
        try await manager.start()

        let stopTask = Task { await manager.stop() }
        await sleepGate.waitForCall()
        let sleepCalls = await sleepGate.recordedCalls()
        XCTAssertEqual(sleepCalls, [.seconds(2)])
        await sleepGate.resumeAll()
        await stopTask.value

        let snapshot = await process.snapshot()
        XCTAssertEqual(snapshot.terminateCount, 1)
        XCTAssertEqual(snapshot.forceKillCount, 1)
        XCTAssertEqual(snapshot.forceKilledPIDs, [7331])
        XCTAssertFalse(snapshot.isRunning)
    }

    func testConcurrentAndRepeatedStopsShareCleanupWithoutDoubleSignal() async throws {
        let process = OwnedProcessFake(terminationBehavior: .staysRunning)
        let sleepGate = ProcessSleepGate()
        let manager = makeManager(
            process: process,
            sleep: { duration in await sleepGate.sleep(duration) }
        )
        try await manager.start()

        let first = Task { await manager.stop() }
        await sleepGate.waitForCall()
        let second = Task { await manager.stop() }
        await sleepGate.resumeAll()
        await first.value
        await second.value
        await manager.stop()

        let snapshot = await process.snapshot()
        XCTAssertEqual(snapshot.terminateCount, 1)
        XCTAssertEqual(snapshot.forceKillCount, 1)
    }

    private func makeManager(
        launcher: ProcessLauncherSpy,
        environment: [String: String]
    ) -> OllamaProcessManager {
        OllamaProcessManager(
            locator: ProcessLocatorStub(result: .success(executableURL)),
            launcher: launcher,
            parentEnvironment: { environment }
        )
    }

    private func makeManager(
        process: OwnedProcessFake,
        sleep: @escaping OllamaProcessStopper.Sleep
    ) -> OllamaProcessManager {
        let launcher = ProcessLauncherSpy(result: .success(process))
        return OllamaProcessManager(
            locator: ProcessLocatorStub(result: .success(executableURL)),
            launcher: launcher,
            parentEnvironment: { [:] },
            stopper: OllamaProcessStopper(
                gracePeriod: .seconds(2),
                sleep: sleep
            )
        )
    }
}
