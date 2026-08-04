import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    private(set) var servers: [DevServer] = []
    private var started = false
    /// First scan dumps everything already running — don't notify for that batch.
    private var readyForNotifications = false

    func start() {
        guard !started else { return }
        started = true
        PortNotifier.requestPermissionIfNeeded()
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
            let project = ProjectDetector.detect(
                workingDirectory: details?.workingDirectory,
                command: details?.command
            )
            if let project {
                scannerLog.info("port \(listener.port) → project \(project.name, privacy: .public) (\(project.framework.rawValue, privacy: .public))")
            }
            let server = DevServer(listener: listener, details: details, project: project)
            updated.append(server)

            if readyForNotifications,
               Preferences.shared.notificationsEnabled,
               !server.isSystemProcess {
                PortNotifier.notifyNewPort(port: server.port, processName: server.processName)
            }
        }
        servers = updated.sorted { $0.port < $1.port }
        readyForNotifications = true
        TunnelManager.shared.prune(activePorts: Set(servers.map(\.port)))
    }
}
