// Modification notice: Changed in 2026 for the Port Radar Offline fork's private local Ollama service.
import Foundation
import Observation

extension LocalAIProviderPreference {
    var usesOllamaControls: Bool {
        switch self {
        case .automatic, .ollama: true
        case .apple: false
        }
    }
}

@MainActor
@Observable
final class OllamaSettingsModel {
    typealias OpenApplication = @MainActor @Sendable () async throws -> Void
    typealias Sleep = @Sendable (Duration) async throws -> Void

    enum State: Equatable {
        case idle
        case loading
        case ready([OllamaModel])
        case notRunning
        case failed(String)

        var statusText: String {
            switch self {
            case .idle:
                "Ollama status has not been checked"
            case .loading:
                "Checking Ollama…"
            case .ready(let models) where models.isEmpty:
                "No local Ollama models found"
            case .ready(let models):
                "Ollama is running · \(models.count) local "
                    + (models.count == 1 ? "model" : "models")
            case .notRunning:
                "Ollama is not running"
            case .failed(let message):
                message
            }
        }
    }

    private let clientProvider: OllamaClientProviding
    private let preferences: Preferences
    @ObservationIgnored private let openApplication: OpenApplication
    @ObservationIgnored private let sleep: Sleep
    private(set) var state: State = .idle
    private(set) var showsDownloadLink = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration = 0

    private static let launchRetryDelays: [Duration] = [
        .milliseconds(250),
        .milliseconds(500),
    ]

    private static let liveOpenApplication: OpenApplication = {
        try await OllamaApplication.open()
    }

    private static let liveSleep: Sleep = { duration in
        try await Task.sleep(for: duration)
    }

    init(
        clientProvider: @escaping OllamaClientProviding =
            PrivateServiceOllamaClient.provider,
        preferences: Preferences = .shared,
        openApplication: @escaping OpenApplication = liveOpenApplication,
        sleep: @escaping Sleep = liveSleep
    ) {
        self.clientProvider = clientProvider
        self.preferences = preferences
        self.openApplication = openApplication
        self.sleep = sleep
    }

    convenience init(
        client: any OllamaClientProtocol,
        preferences: Preferences = .shared,
        openApplication: @escaping OpenApplication = liveOpenApplication,
        sleep: @escaping Sleep = liveSleep
    ) {
        self.init(
            clientProvider: { client },
            preferences: preferences,
            openApplication: openApplication,
            sleep: sleep
        )
    }

    func refresh(selectedModelID: String) {
        let generation = beginOperation()
        let clientProvider = clientProvider

        refreshTask = Task { [weak self] in
            do {
                let models = try await clientProvider().localModels()
                try Task.checkCancellation()
                self?.publish(
                    models: models,
                    selectedModelID: selectedModelID,
                    generation: generation
                )
            } catch is CancellationError {
                return
            } catch {
                self?.publish(error: error, generation: generation)
            }
        }
    }

    func openOllamaAndRetry(selectedModelID: String) {
        let generation = beginOperation()
        let clientProvider = clientProvider
        let openApplication = openApplication
        let sleep = sleep

        refreshTask = Task { [weak self] in
            do {
                try await openApplication()
                try Task.checkCancellation()
            } catch is CancellationError {
                return
            } catch {
                self?.publishOpenFailure(error, generation: generation)
                return
            }

            var retryIndex = 0
            while true {
                do {
                    let models = try await clientProvider().localModels()
                    try Task.checkCancellation()
                    self?.publish(
                        models: models,
                        selectedModelID: selectedModelID,
                        generation: generation
                    )
                    return
                } catch is CancellationError {
                    return
                } catch LocalAIError.ollamaNotRunning {
                    guard retryIndex < Self.launchRetryDelays.count else {
                        self?.publish(
                            error: LocalAIError.ollamaNotRunning,
                            generation: generation
                        )
                        return
                    }

                    let delay = Self.launchRetryDelays[retryIndex]
                    retryIndex += 1
                    do {
                        try await sleep(delay)
                        try Task.checkCancellation()
                    } catch {
                        return
                    }
                } catch {
                    self?.publish(error: error, generation: generation)
                    return
                }
            }
        }
    }

    func cancelRefresh() {
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func beginOperation() -> Int {
        refreshTask?.cancel()
        refreshGeneration &+= 1
        showsDownloadLink = false
        state = .loading
        return refreshGeneration
    }

    private func publish(
        models: [OllamaModel],
        selectedModelID: String,
        generation: Int
    ) {
        guard refreshGeneration == generation, !Task.isCancelled else {
            return
        }

        state = .ready(models)
        if !selectedModelID.isEmpty,
           preferences.ollamaModelID == selectedModelID,
           !models.contains(where: { $0.id == selectedModelID }) {
            preferences.ollamaModelID = ""
        }
        refreshTask = nil
    }

    private func publish(error: any Error, generation: Int) {
        guard refreshGeneration == generation, !Task.isCancelled else {
            return
        }
        state = Self.failureState(for: error)
        refreshTask = nil
    }

    private func publishOpenFailure(_ error: any Error, generation: Int) {
        guard refreshGeneration == generation, !Task.isCancelled else {
            return
        }

        if error as? LocalAIError == .ollamaNotRunning {
            state = .failed("Ollama app was not found.")
        } else {
            state = .failed("Unable to open Ollama.")
        }
        showsDownloadLink = true
        refreshTask = nil
    }

    private static func failureState(for error: any Error) -> State {
        guard let localError = error as? LocalAIError else {
            return .failed("Unable to check local Ollama models.")
        }

        switch localError {
        case .ollamaNotRunning:
            return .notRunning
        case .appleUnavailable:
            return .failed("Unable to check local Ollama models.")
        case .ollamaNotInstalled,
             .ollamaPrivateServiceUnavailable,
             .ollamaModelRequired,
             .ollamaModelUnavailable,
             .remoteModelRejected,
             .unsafeLocalEndpoint,
             .timedOut,
             .malformedResponse:
            return .failed(
                localError.errorDescription
                    ?? "Unable to check local Ollama models."
            )
        }
    }
}
