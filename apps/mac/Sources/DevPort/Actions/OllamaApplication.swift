import AppKit

@MainActor
enum OllamaApplication {
    static func open() async throws {
        try await open(
            locate: { bundleIdentifier in
                NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: bundleIdentifier
                )
            },
            launch: { appURL, activates in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = activates
                try await NSWorkspace.shared.openApplication(
                    at: appURL,
                    configuration: configuration
                )
            }
        )
    }

    static func open(
        locate: (String) -> URL?,
        launch: (URL, Bool) async throws -> Void
    ) async throws {
        guard let appURL = locate("com.electron.ollama") else {
            throw LocalAIError.ollamaNotRunning
        }
        try await launch(appURL, true)
    }
}
