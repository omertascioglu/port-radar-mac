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
    func launch(_ spec: OllamaLaunchSpec) throws -> any OllamaOwnedProcess
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
    typealias MakeProcess = @Sendable () -> Process
    typealias Kill = @Sendable (Int32, Int32) -> Int32

    private let makeProcess: MakeProcess
    private let kill: Kill

    init() {
        makeProcess = { Process() }
        kill = { pid, signal in Darwin.kill(pid, signal) }
    }

#if DEBUG
    init(
        makeProcess: @escaping MakeProcess,
        kill: @escaping Kill
    ) {
        self.makeProcess = makeProcess
        self.kill = kill
    }
#endif

    func launch(_ spec: OllamaLaunchSpec) throws -> any OllamaOwnedProcess {
        guard spec.executableURL.isFileURL,
              spec.arguments == ["serve"],
              spec.host == "127.0.0.1",
              spec.port == 11435,
              spec.environment["OLLAMA_HOST"] == "127.0.0.1:11435",
              spec.environment["OLLAMA_NO_CLOUD"] == "1" else {
            throw FoundationOllamaProcessError.invalidLaunchSpec
        }

        return try FoundationOllamaOwnedProcess(
            spec: spec,
            makeProcess: makeProcess,
            kill: kill
        )
    }
}

private actor FoundationOllamaOwnedProcess: OllamaOwnedProcess {
    private let process: Process
    private let exitSignal: OllamaProcessExitSignal
    private let ownedPID: Int32
    private let kill: FoundationOllamaProcessLauncher.Kill
    private var didRequestTermination = false
    private var didRequestForceKill = false

    init(
        spec: OllamaLaunchSpec,
        makeProcess: FoundationOllamaProcessLauncher.MakeProcess,
        kill: @escaping FoundationOllamaProcessLauncher.Kill
    ) throws {
        let process = makeProcess()
        let exitSignal = OllamaProcessExitSignal()
        process.executableURL = spec.executableURL
        process.arguments = spec.arguments
        process.environment = spec.environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in
            Task {
                await exitSignal.signalExit()
            }
        }
        try process.run()

        self.process = process
        self.exitSignal = exitSignal
        ownedPID = process.processIdentifier
        self.kill = kill
    }

    var processIdentifier: Int32 { ownedPID }
    var isRunning: Bool { process.isRunning }

    func terminate() {
        guard !didRequestTermination else { return }
        didRequestTermination = true
        guard process.isRunning else { return }
        process.terminate()
    }

    func waitForExit() async {
        await exitSignal.waitForExit()
    }

    func forceKill() {
        guard !didRequestForceKill else { return }
        didRequestForceKill = true
        guard process.isRunning else { return }
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

    func start() throws {
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
            ownedProcess = try launcher.launch(spec)
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
