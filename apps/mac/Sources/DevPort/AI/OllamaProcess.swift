// Modification notice: Added in 2026 for the Port Radar Offline fork.
import Darwin
import Foundation

struct OllamaLaunchSpec: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let host: String
    let port: Int
}

protocol OllamaOwnedProcess: Sendable {
    var processIdentifier: Int32 { get async }
    var isRunning: Bool { get async }
    func terminate() async
    func waitForExit() async
    func forceKill() async
}

protocol OllamaProcessLaunching: Sendable {
    func launch(_ spec: OllamaLaunchSpec) async throws -> any OllamaOwnedProcess
}

enum OllamaProcessOutputSink: Equatable, Sendable {
    case null
}

protocol OllamaFoundationProcess: Sendable {
    var processIdentifier: Int32 { get async }
    var isRunning: Bool { get async }
    func setExecutableURL(_ url: URL) async
    func setArguments(_ arguments: [String]) async
    func setEnvironment(_ environment: [String: String]) async
    func setStandardOutput(_ sink: OllamaProcessOutputSink) async
    func setStandardError(_ sink: OllamaProcessOutputSink) async
    func setTerminationHandler(
        _ handler: @escaping @Sendable () -> Void
    ) async
    func run() async throws
    func terminate() async
}

actor OllamaProcessExitSignal {
    private(set) var hasExited = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signalExit() {
        guard !hasExited else { return }
        hasExited = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitForExit() async {
        guard !hasExited else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private enum FoundationOllamaProcessError: Error {
    case invalidLaunchSpec
}

struct FoundationOllamaProcessLauncher: OllamaProcessLaunching, Sendable {
    typealias MakeProcess = @Sendable () -> any OllamaFoundationProcess
    typealias Kill = @Sendable (Int32, Int32) -> Int32

    private let makeProcess: MakeProcess
    private let kill: Kill

    init(
        makeProcess: @escaping MakeProcess = { FoundationOllamaProcess() },
        kill: @escaping Kill = { pid, signal in Darwin.kill(pid, signal) }
    ) {
        self.makeProcess = makeProcess
        self.kill = kill
    }

    func launch(
        _ spec: OllamaLaunchSpec
    ) async throws -> any OllamaOwnedProcess {
        guard spec.executableURL.isFileURL,
              spec.arguments == ["serve"],
              spec.host == "127.0.0.1",
              spec.port == 11435,
              spec.environment["OLLAMA_HOST"] == "127.0.0.1:11435",
              spec.environment["OLLAMA_NO_CLOUD"] == "1" else {
            throw FoundationOllamaProcessError.invalidLaunchSpec
        }

        let process = makeProcess()
        let exitSignal = OllamaProcessExitSignal()
        await process.setExecutableURL(spec.executableURL)
        await process.setArguments(spec.arguments)
        await process.setEnvironment(spec.environment)
        await process.setStandardOutput(.null)
        await process.setStandardError(.null)
        await process.setTerminationHandler {
            Task {
                await exitSignal.signalExit()
            }
        }
        try await process.run()

        return FoundationOllamaOwnedProcess(
            process: process,
            exitSignal: exitSignal,
            ownedPID: await process.processIdentifier,
            kill: kill
        )
    }
}

private actor FoundationOllamaProcess: OllamaFoundationProcess {
    private let process = Process()

    var processIdentifier: Int32 {
        process.processIdentifier
    }

    var isRunning: Bool {
        process.isRunning
    }

    func setExecutableURL(_ url: URL) {
        process.executableURL = url
    }

    func setArguments(_ arguments: [String]) {
        process.arguments = arguments
    }

    func setEnvironment(_ environment: [String: String]) {
        process.environment = environment
    }

    func setStandardOutput(_ sink: OllamaProcessOutputSink) {
        switch sink {
        case .null:
            process.standardOutput = FileHandle.nullDevice
        }
    }

    func setStandardError(_ sink: OllamaProcessOutputSink) {
        switch sink {
        case .null:
            process.standardError = FileHandle.nullDevice
        }
    }

    func setTerminationHandler(_ handler: @escaping @Sendable () -> Void) {
        process.terminationHandler = { _ in handler() }
    }

    func run() throws {
        try process.run()
    }

    func terminate() async {
        process.terminate()
    }
}

private actor FoundationOllamaOwnedProcess: OllamaOwnedProcess {
    private let process: any OllamaFoundationProcess
    private let exitSignal: OllamaProcessExitSignal
    private let ownedPID: Int32
    private let kill: FoundationOllamaProcessLauncher.Kill
    private var didRequestTermination = false
    private var didRequestForceKill = false

    init(
        process: any OllamaFoundationProcess,
        exitSignal: OllamaProcessExitSignal,
        ownedPID: Int32,
        kill: @escaping FoundationOllamaProcessLauncher.Kill
    ) {
        self.process = process
        self.exitSignal = exitSignal
        self.ownedPID = ownedPID
        self.kill = kill
    }

    var processIdentifier: Int32 { ownedPID }
    var isRunning: Bool {
        get async { await process.isRunning }
    }

    func terminate() async {
        guard !didRequestTermination else { return }
        didRequestTermination = true
        guard await process.isRunning else { return }
        await process.terminate()
    }

    func waitForExit() async {
        await exitSignal.waitForExit()
    }

    func forceKill() async {
        guard !didRequestForceKill else { return }
        didRequestForceKill = true
        guard await process.isRunning else { return }
        _ = kill(ownedPID, SIGKILL)
    }
}

private actor OllamaStopRace {
    enum Winner: Sendable {
        case exited
        case graceExpired
    }

    private var winner: Winner?
    private var waiter: CheckedContinuation<Winner, Never>?

    func finish(_ result: Winner) {
        guard winner == nil else { return }
        winner = result
        waiter?.resume(returning: result)
        waiter = nil
    }

    func value() async -> Winner {
        if let winner { return winner }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }
}

struct OllamaProcessStopper: Sendable {
    typealias Sleep = @Sendable (Duration) async -> Void

    let gracePeriod: Duration
    private let sleep: Sleep

    init(
        gracePeriod: Duration = .seconds(2),
        sleep: @escaping Sleep = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        self.gracePeriod = gracePeriod
        self.sleep = sleep
    }

    func stop(_ process: any OllamaOwnedProcess) async {
        await process.terminate()
        guard await process.isRunning else {
            await process.waitForExit()
            return
        }

        let race = OllamaStopRace()
        let exitTask = Task {
            await process.waitForExit()
            await race.finish(.exited)
        }
        let timeoutTask = Task {
            await sleep(gracePeriod)
            guard !Task.isCancelled else { return }
            await race.finish(.graceExpired)
        }

        switch await race.value() {
        case .exited:
            timeoutTask.cancel()
        case .graceExpired:
            if await process.isRunning {
                await process.forceKill()
            }
            await exitTask.value
        }
    }
}

actor OllamaProcessManager {
    typealias ParentEnvironment = @Sendable () -> [String: String]

    private static let host = "127.0.0.1"
    private static let port = 11435
    private static let allowedEnvironmentKeys: Set<String> = [
        "PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
        "OLLAMA_MODELS",
    ]

    private let locator: any OllamaExecutableLocating
    private let launcher: any OllamaProcessLaunching
    private let parentEnvironment: ParentEnvironment
    private let stopper: OllamaProcessStopper
    private var ownedProcess: (any OllamaOwnedProcess)?
    private var stopTask: Task<Void, Never>?

    init(
        locator: any OllamaExecutableLocating = OllamaExecutableLocator(),
        launcher: any OllamaProcessLaunching = FoundationOllamaProcessLauncher(),
        parentEnvironment: @escaping ParentEnvironment = {
            ProcessInfo.processInfo.environment
        },
        stopper: OllamaProcessStopper = OllamaProcessStopper()
    ) {
        self.locator = locator
        self.launcher = launcher
        self.parentEnvironment = parentEnvironment
        self.stopper = stopper
    }

    func start() async throws {
        guard ownedProcess == nil, stopTask == nil else { return }

        let executableURL: URL
        do {
            executableURL = try locator.locate()
        } catch OllamaExecutableLocatorError.notInstalled {
            throw LocalAIError.ollamaNotInstalled
        } catch {
            throw LocalAIError.ollamaPrivateServiceUnavailable
        }

        let spec = OllamaLaunchSpec(
            executableURL: executableURL,
            arguments: ["serve"],
            environment: Self.makeEnvironment(from: parentEnvironment()),
            host: Self.host,
            port: Self.port
        )

        do {
            ownedProcess = try await launcher.launch(spec)
        } catch {
            throw LocalAIError.ollamaPrivateServiceUnavailable
        }
    }

    func stop() async {
        if let stopTask {
            await stopTask.value
            return
        }
        guard let process = ownedProcess else { return }
        ownedProcess = nil

        let stopper = stopper
        let task = Task {
            await stopper.stop(process)
        }
        stopTask = task
        await task.value
        stopTask = nil
    }

    private static func makeEnvironment(
        from parent: [String: String]
    ) -> [String: String] {
        var environment = parent.filter {
            allowedEnvironmentKeys.contains($0.key)
        }
        environment["OLLAMA_HOST"] = "127.0.0.1:11435"
        environment["OLLAMA_NO_CLOUD"] = "1"
        return environment
    }
}
