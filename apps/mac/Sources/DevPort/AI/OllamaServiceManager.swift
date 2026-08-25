// Modification notice: Added in 2026 for the Port Radar Offline fork.
import Darwin
import Foundation

struct OllamaServiceEndpoint: Equatable, Sendable {
    let baseURL: URL
    let processIdentifier: Int32
}

struct OllamaServiceLease: Sendable {
    let endpoint: OllamaServiceEndpoint
    private let releaseRegistration: OllamaLeaseReleaseRegistration

    fileprivate init(
        endpoint: OllamaServiceEndpoint,
        releaseRegistration: OllamaLeaseReleaseRegistration
    ) {
        self.endpoint = endpoint
        self.releaseRegistration = releaseRegistration
    }

    func release() async {
        await releaseRegistration.release()
    }

    #if DEBUG
    static func testInstance(
        endpoint: OllamaServiceEndpoint
    ) -> OllamaServiceLease {
        OllamaServiceLease(
            endpoint: endpoint,
            releaseRegistration: OllamaLeaseReleaseRegistration {}
        )
    }
    #endif
}

private actor OllamaLeaseReleaseRegistration {
    typealias Release = @Sendable () async -> Void

    private let releaseAction: Release
    private var didRelease = false

    init(releaseAction: @escaping Release) {
        self.releaseAction = releaseAction
    }

    func release() async {
        guard !didRelease else { return }
        didRelease = true
        await releaseAction()
    }
}

struct OllamaReadinessResponse: Equatable, Sendable {
    let finalURL: URL
    let statusCode: Int
    let hasVersion: Bool
}

protocol OllamaServiceProcessControlling: Sendable {
    func start() async throws -> any OllamaOwnedProcess
    func stop() async
}

protocol OllamaServicePortChecking: Sendable {
    func isAvailable(host: String, port: Int) -> Bool
}

protocol OllamaServiceReadinessProbing: Sendable {
    func probe(_ url: URL) async throws -> OllamaReadinessResponse
}

private struct LiveOllamaServiceProcessController:
    OllamaServiceProcessControlling,
    Sendable
{
    let processManager: OllamaProcessManager

    func start() async throws -> any OllamaOwnedProcess {
        try await processManager.startOwnedProcess()
    }

    func stop() async {
        await processManager.stop()
    }
}

private struct LoopbackPortAvailabilityChecker:
    OllamaServicePortChecking,
    Sendable
{
    func isAvailable(host: String, port: Int) -> Bool {
        guard host == "127.0.0.1", port == 11435 else { return false }

        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard host.withCString({
            Darwin.inet_pton(AF_INET, $0, &address.sin_addr)
        }) == 1 else {
            return false
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) { socketAddress in
                Darwin.bind(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        return result == 0
    }
}

private final class OllamaReadinessSessionDelegate:
    NSObject,
    URLSessionTaskDelegate,
    URLSessionDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

private struct URLSessionOllamaReadinessProbe:
    OllamaServiceReadinessProbing,
    Sendable
{
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 1
        session = URLSession(
            configuration: configuration,
            delegate: OllamaReadinessSessionDelegate(),
            delegateQueue: nil
        )
    }

    func probe(_ url: URL) async throws -> OllamaReadinessResponse {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse,
              let finalURL = http.url else {
            throw LocalAIError.ollamaPrivateServiceUnavailable
        }
        let object = try? JSONSerialization.jsonObject(with: data)
        let version = (object as? [String: Any])?["version"] as? String
        return OllamaReadinessResponse(
            finalURL: finalURL,
            statusCode: http.statusCode,
            hasVersion: version?.isEmpty == false
        )
    }
}

actor OllamaServiceManager {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    static let shared = OllamaServiceManager.live()

    private static let host = "127.0.0.1"
    private static let port = 11435
    private static let baseURL = URL(string: "http://127.0.0.1:11435")!
    private static let versionURL = URL(
        string: "http://127.0.0.1:11435/api/version"
    )!

    private struct StartupState {
        let id: UUID
        let task: Task<StartupResult, Error>
        var acceptsWaiters: Bool
    }

    private struct StartupResult: Sendable {
        let endpoint: OllamaServiceEndpoint
        let process: any OllamaOwnedProcess
    }

    private struct StopState {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let processController: any OllamaServiceProcessControlling
    private let portChecker: any OllamaServicePortChecking
    private let readinessProbe: any OllamaServiceReadinessProbing
    private let sleep: Sleep
    private let readinessAttempts: Int
    private let readinessInterval: Duration

    private var startup: StartupState?
    private var pendingAcquires: [UUID: UUID] = [:]
    private var activeEndpoint: OllamaServiceEndpoint?
    private var activeProcess: (any OllamaOwnedProcess)?
    private var activeGeneration: UInt64 = 0
    private var leaseIDs: Set<UUID> = []
    private var stopState: StopState?
    private var isShutDown = false

    init(
        processController: any OllamaServiceProcessControlling,
        portChecker: any OllamaServicePortChecking,
        readinessProbe: any OllamaServiceReadinessProbing,
        sleep: @escaping Sleep,
        readinessAttempts: Int,
        readinessInterval: Duration
    ) {
        self.processController = processController
        self.portChecker = portChecker
        self.readinessProbe = readinessProbe
        self.sleep = sleep
        self.readinessAttempts = max(1, readinessAttempts)
        self.readinessInterval = readinessInterval
    }

    static func live() -> OllamaServiceManager {
        let processManager = OllamaProcessManager()
        return OllamaServiceManager(
            processController: LiveOllamaServiceProcessController(
                processManager: processManager
            ),
            portChecker: LoopbackPortAvailabilityChecker(),
            readinessProbe: URLSessionOllamaReadinessProbe(),
            sleep: { duration in
                try await Task.sleep(for: duration)
            },
            readinessAttempts: 30,
            readinessInterval: .milliseconds(100)
        )
    }

    func acquire() async throws -> OllamaServiceLease {
        try Task.checkCancellation()
        guard !isShutDown else { throw privateServiceError() }

        if let stopState {
            await waitForStop(stopState)
            try Task.checkCancellation()
            return try await acquire()
        }

        if let activeEndpoint {
            guard let activeProcess else {
                self.activeEndpoint = nil
                leaseIDs.removeAll()
                await stopController()
                throw privateServiceError()
            }

            // The liveness check suspends, and this actor is reentrant, so a
            // final release or shutdown can retire this service generation
            // while we wait. Re-validate before binding a lease to it.
            let generation = activeGeneration
            let isRunning = await activeProcess.isRunning
            guard !isShutDown else { throw privateServiceError() }
            guard activeGeneration == generation,
                  self.activeEndpoint == activeEndpoint,
                  stopState == nil else {
                try Task.checkCancellation()
                return try await acquire()
            }
            guard isRunning else {
                self.activeEndpoint = nil
                self.activeProcess = nil
                leaseIDs.removeAll()
                await stopController()
                throw privateServiceError()
            }
            return makeLease(endpoint: activeEndpoint)
        }

        if let startup, !startup.acceptsWaiters {
            _ = await startup.task.result
            finishStartupIfUnowned(startup.id)
            try Task.checkCancellation()
            return try await acquire()
        }

        let requestID = UUID()
        let startupState = existingOrNewStartup()
        pendingAcquires[requestID] = startupState.id

        do {
            let result = try await withTaskCancellationHandler {
                try await startupState.task.value
            } onCancel: {
                Task {
                    await self.cancelPendingAcquire(
                        requestID,
                        startupID: startupState.id
                    )
                }
            }

            if Task.isCancelled {
                cancelPendingAcquire(requestID, startupID: startupState.id)
                await stopCompletedStartupIfUnowned(startupState.id)
                throw CancellationError()
            }

            return try await adoptReadyService(
                result,
                requestID: requestID,
                startupID: startupState.id
            )
        } catch {
            finishFailedAcquire(requestID, startupID: startupState.id)
            if isShutDown { throw privateServiceError() }
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            if error as? LocalAIError == .ollamaNotInstalled {
                throw LocalAIError.ollamaNotInstalled
            }
            throw privateServiceError()
        }
    }

    func shutdownAll() async {
        guard !isShutDown else {
            if let stopState { await waitForStop(stopState) }
            return
        }
        isShutDown = true
        let hadActiveService = activeEndpoint != nil
        leaseIDs.removeAll()
        activeEndpoint = nil
        activeProcess = nil

        if var startup {
            startup.acceptsWaiters = false
            self.startup = startup
            startup.task.cancel()
            let result = await startup.task.result
            if case .success = result {
                await stopController()
            }
            finishStartupIfUnowned(startup.id)
        }

        if hadActiveService || stopState != nil {
            await stopController()
        }
    }

#if DEBUG
    func pendingAcquireCountForTesting() -> Int {
        pendingAcquires.count
    }
#endif

    private func existingOrNewStartup() -> StartupState {
        if let startup { return startup }

        let id = UUID()
        let processController = processController
        let portChecker = portChecker
        let readinessProbe = readinessProbe
        let sleep = sleep
        let readinessAttempts = readinessAttempts
        let readinessInterval = readinessInterval
        let task = Task {
            try await Self.startService(
                processController: processController,
                portChecker: portChecker,
                readinessProbe: readinessProbe,
                sleep: sleep,
                readinessAttempts: readinessAttempts,
                readinessInterval: readinessInterval
            )
        }
        let state = StartupState(id: id, task: task, acceptsWaiters: true)
        startup = state
        return state
    }

    private static func startService(
        processController: any OllamaServiceProcessControlling,
        portChecker: any OllamaServicePortChecking,
        readinessProbe: any OllamaServiceReadinessProbing,
        sleep: @escaping Sleep,
        readinessAttempts: Int,
        readinessInterval: Duration
    ) async throws -> StartupResult {
        try Task.checkCancellation()
        guard portChecker.isAvailable(host: host, port: port) else {
            throw LocalAIError.ollamaPrivateServiceUnavailable
        }

        let process: any OllamaOwnedProcess
        do {
            process = try await processController.start()
        } catch let error as LocalAIError where error == .ollamaNotInstalled {
            throw error
        } catch {
            throw LocalAIError.ollamaPrivateServiceUnavailable
        }

        do {
            for attempt in 0..<readinessAttempts {
                try Task.checkCancellation()
                guard await process.isRunning else {
                    throw LocalAIError.ollamaPrivateServiceUnavailable
                }

                do {
                    let response = try await readinessProbe.probe(versionURL)
                    try Task.checkCancellation()
                    guard response.finalURL == versionURL else {
                        throw LocalAIError.unsafeLocalEndpoint
                    }
                    if response.statusCode == 200, response.hasVersion {
                        guard await process.isRunning else {
                            throw LocalAIError.ollamaPrivateServiceUnavailable
                        }
                        return StartupResult(
                            endpoint: OllamaServiceEndpoint(
                                baseURL: baseURL,
                                processIdentifier:
                                    await process.processIdentifier
                            ),
                            process: process
                        )
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch LocalAIError.unsafeLocalEndpoint {
                    throw LocalAIError.unsafeLocalEndpoint
                } catch {
                    // A not-yet-ready loopback service is retried within the bound.
                }

                if attempt + 1 < readinessAttempts {
                    try await sleep(readinessInterval)
                }
            }
            throw LocalAIError.ollamaPrivateServiceUnavailable
        } catch {
            await processController.stop()
            if error is CancellationError { throw CancellationError() }
            throw LocalAIError.ollamaPrivateServiceUnavailable
        }
    }

    private func adoptReadyService(
        _ result: StartupResult,
        requestID: UUID,
        startupID: UUID
    ) async throws -> OllamaServiceLease {
        pendingAcquires.removeValue(forKey: requestID)

        guard !isShutDown else {
            finishStartupIfUnowned(startupID)
            await stopController()
            throw privateServiceError()
        }

        if let activeEndpoint {
            guard activeEndpoint == result.endpoint else {
                await stopController()
                throw privateServiceError()
            }
            return makeLease(endpoint: activeEndpoint)
        }

        guard startup?.id == startupID else {
            await stopController()
            throw privateServiceError()
        }
        activeEndpoint = result.endpoint
        activeProcess = result.process
        activeGeneration &+= 1
        startup = nil
        return makeLease(endpoint: result.endpoint)
    }

    private func makeLease(endpoint: OllamaServiceEndpoint) -> OllamaServiceLease {
        let leaseID = UUID()
        leaseIDs.insert(leaseID)
        let registration = OllamaLeaseReleaseRegistration { [self] in
            await releaseLease(leaseID)
        }
        return OllamaServiceLease(
            endpoint: endpoint,
            releaseRegistration: registration
        )
    }

    private func releaseLease(_ leaseID: UUID) async {
        guard leaseIDs.remove(leaseID) != nil else { return }
        guard leaseIDs.isEmpty, activeEndpoint != nil else { return }
        activeEndpoint = nil
        activeProcess = nil
        await stopController()
    }

    private func cancelPendingAcquire(_ requestID: UUID, startupID: UUID) {
        guard pendingAcquires[requestID] == startupID else { return }
        pendingAcquires.removeValue(forKey: requestID)
        guard !pendingAcquires.values.contains(startupID),
              var startup,
              startup.id == startupID else {
            return
        }
        startup.acceptsWaiters = false
        self.startup = startup
        startup.task.cancel()
    }

    private func finishFailedAcquire(_ requestID: UUID, startupID: UUID) {
        if pendingAcquires[requestID] == startupID {
            pendingAcquires.removeValue(forKey: requestID)
        }
        guard !pendingAcquires.values.contains(startupID) else { return }
        finishStartupIfUnowned(startupID)
    }

    private func finishStartupIfUnowned(_ startupID: UUID) {
        guard startup?.id == startupID,
              activeEndpoint == nil,
              !pendingAcquires.values.contains(startupID) else {
            return
        }
        startup = nil
    }

    private func stopCompletedStartupIfUnowned(_ startupID: UUID) async {
        guard activeEndpoint == nil,
              !pendingAcquires.values.contains(startupID) else {
            return
        }
        finishStartupIfUnowned(startupID)
        await stopController()
    }

    private func stopController() async {
        if let stopState {
            await waitForStop(stopState)
            return
        }
        let id = UUID()
        let processController = processController
        let state = StopState(
            id: id,
            task: Task { await processController.stop() }
        )
        stopState = state
        await waitForStop(state)
    }

    private func waitForStop(_ state: StopState) async {
        await state.task.value
        if stopState?.id == state.id {
            stopState = nil
        }
    }

    private func privateServiceError() -> LocalAIError {
        .ollamaPrivateServiceUnavailable
    }
}
