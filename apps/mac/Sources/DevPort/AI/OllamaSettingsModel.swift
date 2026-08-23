import Foundation
import Observation

@MainActor
@Observable
final class OllamaSettingsModel {
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

    private let client: any OllamaClientProtocol
    private let preferences: Preferences
    private(set) var state: State = .idle
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration = 0

    init(
        client: any OllamaClientProtocol = OllamaClient(),
        preferences: Preferences = .shared
    ) {
        self.client = client
        self.preferences = preferences
    }

    func refresh(selectedModelID: String) {
        refreshTask?.cancel()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let client = client
        state = .loading

        refreshTask = Task { [weak self] in
            do {
                let models = try await client.localModels()
                try Task.checkCancellation()

                guard let self, self.refreshGeneration == generation else {
                    return
                }

                self.state = .ready(models)
                if !selectedModelID.isEmpty,
                   self.preferences.ollamaModelID == selectedModelID,
                   !models.contains(where: { $0.id == selectedModelID }) {
                    self.preferences.ollamaModelID = ""
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.refreshGeneration == generation,
                      !Task.isCancelled
                else {
                    return
                }
                self.state = Self.failureState(for: error)
            }
        }
    }

    func cancelRefresh() {
        refreshGeneration &+= 1
        refreshTask?.cancel()
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
        case .ollamaModelRequired,
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
