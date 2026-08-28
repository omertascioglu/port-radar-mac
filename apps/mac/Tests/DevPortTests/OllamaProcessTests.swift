// Modification notice: Added in 2026 for the Port Radar Offline fork.
import Darwin
import Foundation
import XCTest
@testable import DevPort

private enum ProcessTestError: Error {
    case launchFailed
    case locatorFailed(String)
}

private final class FoundationProcessFake: Process, @unchecked Sendable {
    struct Snapshot: Equatable {
        let executableURL: URL?
        let arguments: [String]
        let environment: [String: String]
        let standardOutputIsNull: Bool
        let standardErrorIsNull: Bool
        let standardOutputWasPipe: Bool
        let standardErrorWasPipe: Bool
        let events: [String]
        let terminateCount: Int
    }

    private let lock = NSLock()
    private let storedPID: Int32
    private let runError: (any Error)?
    private var storedExecutableURL: URL?
    private var storedArguments: [String] = []
    private var storedEnvironment: [String: String] = [:]
    private var outputIsNull = false
    private var errorIsNull = false
    private var outputWasPipe = false
    private var errorWasPipe = false
    private var storedTerminationHandler: (@Sendable (Process) -> Void)?
    private var events: [String] = []
    private var storedRunning = true
    private var terminateCount = 0

    init(processIdentifier: Int32, runError: (any Error)? = nil) {
        storedPID = processIdentifier
        self.runError = runError
    }

    override var processIdentifier: Int32 { storedPID }
    override var isRunning: Bool { lock.withLock { storedRunning } }

    override var executableURL: URL? {
        get { lock.withLock { storedExecutableURL } }
        set { lock.withLock { storedExecutableURL = newValue } }
    }

    override var arguments: [String]? {
        get { lock.withLock { storedArguments } }
        set { lock.withLock { storedArguments = newValue ?? [] } }
    }

    override var environment: [String: String]? {
        get { lock.withLock { storedEnvironment } }
        set { lock.withLock { storedEnvironment = newValue ?? [:] } }
    }

    override var standardOutput: Any? {
        get { nil }
        set {
            lock.withLock {
                outputIsNull = (newValue as? FileHandle) === FileHandle.nullDevice
                outputWasPipe = newValue is Pipe
            }
        }
    }

    override var standardError: Any? {
        get { nil }
        set {
            lock.withLock {
                errorIsNull = (newValue as? FileHandle) === FileHandle.nullDevice
                errorWasPipe = newValue is Pipe
            }
        }
    }

    override var terminationHandler: (@Sendable (Process) -> Void)? {
        get { lock.withLock { storedTerminationHandler } }
        set {
            lock.withLock {
                storedTerminationHandler = newValue
                events.append("terminationHandler")
            }
        }
    }

    override func run() throws {
        lock.withLock { events.append("run") }
        if let runError { throw runError }
    }

    override func terminate() {
        lock.withLock { terminateCount += 1 }
    }

    func simulateExit() {
        let handler = lock.withLock { () -> (@Sendable (Process) -> Void)? in
            storedRunning = false
            return storedTerminationHandler
        }
        handler?(self)
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                executableURL: storedExecutableURL,
                arguments: storedArguments,
                environment: storedEnvironment,
                standardOutputIsNull: outputIsNull,
                standardErrorIsNull: errorIsNull,
                standardOutputWasPipe: outputWasPipe,
                standardErrorWasPipe: errorWasPipe,
                events: events,
                terminateCount: terminateCount
            )
        }
    }
}

private final class KillSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(Int32, Int32)] = []

    func call(_ pid: Int32, _ signal: Int32) -> Int32 {
        lock.withLock { calls.append((pid, signal)) }
        return 0
    }

    var recordedCalls: [(Int32, Int32)] {
        lock.withLock { calls }
    }
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
        let waitForExitCount: Int
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
            forceKilledPIDs: forceKilledPIDs,
            waitForExitCount: waitForExitCount
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

    func testFoundationLauncherConfiguresNullSinksAndHandlerBeforeRun() async throws {
        let process = FoundationProcessFake(processIdentifier: 8123)
        let launcher = FoundationOllamaProcessLauncher(
            makeProcess: { process },
            kill: { _, _ in 0 }
        )
        let spec = exactLaunchSpec()

        _ = try launcher.launch(spec)

        let snapshot = process.snapshot()
        XCTAssertEqual(snapshot.executableURL, spec.executableURL)
        XCTAssertEqual(snapshot.arguments, spec.arguments)
        XCTAssertEqual(snapshot.environment, spec.environment)
        XCTAssertTrue(snapshot.standardOutputIsNull)
        XCTAssertTrue(snapshot.standardErrorIsNull)
        XCTAssertFalse(snapshot.standardOutputWasPipe)
        XCTAssertFalse(snapshot.standardErrorWasPipe)
        XCTAssertEqual(snapshot.events, ["terminationHandler", "run"])
    }

    func testFoundationOwnedAdapterUsesExactPIDAndIdempotentSignals() async throws {
        let process = FoundationProcessFake(processIdentifier: 8123)
        let killSpy = KillSpy()
        let launcher = FoundationOllamaProcessLauncher(
            makeProcess: { process },
            kill: { pid, signal in killSpy.call(pid, signal) }
        )
        let owned = try launcher.launch(exactLaunchSpec())

        await owned.terminate()
        await owned.terminate()
        await owned.forceKill()
        await owned.forceKill()
        process.simulateExit()
        await owned.waitForExit()

        let snapshot = process.snapshot()
        XCTAssertEqual(snapshot.terminateCount, 1)
        XCTAssertEqual(killSpy.recordedCalls.count, 1)
        XCTAssertEqual(killSpy.recordedCalls.first?.0, 8123)
        XCTAssertEqual(killSpy.recordedCalls.first?.1, SIGKILL)
    }

    func testProductionFoundationProcessIsActorOwnedWithoutLockWrapper() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot.appendingPathComponent(
            "Sources/DevPort/AI/OllamaProcess.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("private actor FoundationOllamaOwnedProcess:"),
            "Raw Foundation.Process ownership must remain actor-isolated"
        )
        XCTAssertTrue(source.contains("private let process: Process"))
        XCTAssertFalse(source.contains("OSAllocatedUnfairLock"))
        XCTAssertTrue(
            source.contains(
                "func launch(_ spec: OllamaLaunchSpec) throws -> any OllamaOwnedProcess"
            )
        )
        XCTAssertTrue(source.contains("func start() throws"))
    }

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

    func testSynchronousFoundationRunFailureMapsToBoundedManagerError() async {
        let process = FoundationProcessFake(
            processIdentifier: 0,
            runError: ProcessTestError.launchFailed
        )
        let launcher = FoundationOllamaProcessLauncher(
            makeProcess: { process },
            kill: { _, _ in 0 }
        )
        let manager = OllamaProcessManager(
            locator: ProcessLocatorStub(result: .success(executableURL)),
            launcher: launcher,
            parentEnvironment: { [:] }
        )

        do {
            try await manager.start()
            XCTFail("Expected synchronous Foundation run failure")
        } catch {
            XCTAssertEqual(
                error as? LocalAIError,
                .ollamaPrivateServiceUnavailable
            )
            XCTAssertEqual(
                (error as? LocalAIError)?.errorDescription,
                "Unable to start the private local Ollama service."
            )
        }
        XCTAssertEqual(
            process.snapshot().events,
            ["terminationHandler", "run"]
        )
    }

    func testUnexpectedLocatorFailureMapsToBoundedGenericMessage() async {
        let process = OwnedProcessFake(terminationBehavior: .exits)
        let launcher = ProcessLauncherSpy(result: .success(process))
        let manager = OllamaProcessManager(
            locator: ProcessLocatorStub(
                result: .failure(
                    ProcessTestError.locatorFailed("/secret/path api-token")
                )
            ),
            launcher: launcher,
            parentEnvironment: { [:] }
        )

        do {
            try await manager.start()
            XCTFail("Expected private service error")
        } catch {
            XCTAssertEqual(
                error as? LocalAIError,
                .ollamaPrivateServiceUnavailable
            )
            XCTAssertEqual(
                (error as? LocalAIError)?.errorDescription,
                "Unable to start the private local Ollama service."
            )
            XCTAssertFalse(
                ((error as? LocalAIError)?.errorDescription ?? "")
                    .contains("api-token")
            )
        }
        XCTAssertTrue(launcher.specs.isEmpty)
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
        XCTAssertEqual(snapshot.waitForExitCount, 1)
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
        XCTAssertEqual(snapshot.waitForExitCount, 1)
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
        XCTAssertEqual(snapshot.waitForExitCount, 1)
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
        XCTAssertEqual(snapshot.waitForExitCount, 1)
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

    private func exactLaunchSpec() -> OllamaLaunchSpec {
        OllamaLaunchSpec(
            executableURL: executableURL,
            arguments: ["serve"],
            environment: [
                "PATH": "/usr/bin:/bin",
                "OLLAMA_HOST": "127.0.0.1:11435",
                "OLLAMA_NO_CLOUD": "1",
            ],
            host: "127.0.0.1",
            port: 11435
        )
    }
}
