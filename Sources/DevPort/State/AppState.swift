import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    private(set) var servers: [DevServer] = []
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        Task {
            let events = await ScannerLoop.shared.events()
            await ScannerLoop.shared.start()
            for await diff in events {
                apply(diff)
            }
        }
    }

    private func apply(_ diff: ScanDiff) {
        var updated = servers.filter { server in
            !diff.removed.contains(ListeningPort(port: server.port, pid: server.pid))
        }
        for listener in diff.added {
            // Resolution can fail if the process died mid-scan; keep the bare port.
            let details = ProcessResolver.resolve(pid: listener.pid)
            updated.append(DevServer(listener: listener, details: details))
        }
        servers = updated.sorted { $0.port < $1.port }
    }
}
