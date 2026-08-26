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
    /// Acquires one temporary lease on the fork's private local service.
    typealias AcquireService = @Sendable () async throws -> OllamaServiceLease

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

        /// Plain guidance shown under the status text. Port Radar Offline never
        /// downloads Ollama or a model, so this copy stays non-clickable and
        /// carries no address: installing a model happens outside the app.
        var installationGuidance: String? {
            guard case .ready(let models) = self, models.isEmpty else {
                return nil
            }
            return "Install a local model with Ollama outside "
                + "Port Radar Offline, then check again."
        }

        /// Title of the only control that starts a check. Nothing else in
        /// Settings starts the private service.
        var checkButtonTitle: String {
            switch self {
            case .idle: "Check local models"
            case .loading, .ready, .notRunning, .failed: "Refresh"
            }
        }
    }

    private let acquireService: AcquireService
    private let preferences: Preferences
    private let makeClient: OllamaClientFactory
    private(set) var state: State = .idle
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration = 0

    init(
        acquireService: @escaping AcquireService = {
            try await OllamaServiceManager.shared.acquire()
        },
        preferences: Preferences = .shared,
        makeClient: @escaping OllamaClientFactory =
            PrivateServiceOllamaClient.factory
    ) {
        self.acquireService = acquireService
        self.preferences = preferences
        self.makeClient = makeClient
    }

    /// Borrows the private local service for one listing and gives it straight
    /// back: the child service outlives a settings check only if a
    /// conversation holds its own lease.
    func refresh(selectedModelID: String) {
        let generation = beginOperation()
        let acquireService = acquireService
        let makeClient = makeClient

        refreshTask = Task { [weak self] in
            let lease: OllamaServiceLease
            do {
                try Task.checkCancellation()
                lease = try await acquireService()
            } catch is CancellationError {
                return
            } catch {
                self?.publish(error: error, generation: generation)
                return
            }

            // Every path below releases this lease exactly once, including the
            // one where the lease only arrives after the refresh was cancelled.
            do {
                try Task.checkCancellation()
                let models = try await makeClient(lease).localModels()
                try Task.checkCancellation()
                await lease.release()
                self?.publish(
                    models: models,
                    selectedModelID: selectedModelID,
                    generation: generation
                )
            } catch {
                await lease.release()
                guard !(error is CancellationError) else { return }
                self?.publish(error: error, generation: generation)
            }
        }
    }

    /// Cancels the operation in flight so its lease is released and nothing it
    /// learned can still be published. An interrupted check leaves the control
    /// ready for another one instead of a row that spins forever.
    func cancelRefresh() {
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        if state == .loading {
            state = .idle
        }
    }

    private func beginOperation() -> Int {
        refreshTask?.cancel()
        refreshGeneration &+= 1
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
