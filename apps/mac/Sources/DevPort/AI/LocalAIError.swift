// Modification notice: Changed in 2026 for the local AI and optional Ollama fallback contribution, and for the Port Radar Offline fork product identity.
import Foundation

enum LocalAIError: Error, Equatable, LocalizedError, Sendable {
    case appleUnavailable(String)
    case ollamaNotRunning
    case ollamaModelRequired
    case ollamaModelUnavailable
    case remoteModelRejected
    case unsafeLocalEndpoint
    case timedOut
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .appleUnavailable(let reason): reason
        case .ollamaNotRunning: "Ollama is not running."
        case .ollamaModelRequired: "Choose an installed local Ollama model."
        case .ollamaModelUnavailable:
            "The selected local Ollama model is no longer available."
        case .remoteModelRejected:
            "Cloud and remote Ollama models are not allowed."
        case .unsafeLocalEndpoint:
            "Ollama redirected outside Port Radar Offline's local-only boundary."
        case .timedOut: "The local model took too long to respond."
        case .malformedResponse:
            "Ollama returned an unreadable response."
        }
    }
}
