// Modification notice: Changed in 2026 for the local AI and optional Ollama fallback contribution.
import Foundation

/// A detected listening server, enriched with process details when available.
struct DevServer: Identifiable, Sendable {
    let port: Int
    let pid: Int32
    let parentPID: Int32?
    let command: String?
    let commandArguments: [String]?
    let executablePath: String?
    let workingDirectory: String?
    let startTime: Date?
    let project: ProjectInfo?

    var id: String { "\(pid):\(port)" }

    var url: URL { URL(string: "http://localhost:\(port)")! }

    /// Short display name: last path component of the executable.
    var processName: String {
        guard let executablePath else { return "pid \(pid)" }
        return URL(fileURLWithPath: executablePath).lastPathComponent
    }

    /// True when the executable lives in a macOS system location
    /// (e.g. rapportd, ControlCenter) rather than a user/dev install.
    var isSystemProcess: Bool {
        guard let executablePath else { return false }
        let systemPrefixes = [
            "/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/",
        ]
        return systemPrefixes.contains { executablePath.hasPrefix($0) }
    }

    /// Parent is gone or reparented to launchd — likely a forgotten terminal session.
    var isOrphaned: Bool {
        guard !isSystemProcess else { return false }
        guard let parentPID else { return false }
        if parentPID <= 1 {
            // Many GUI apps are launchd children; only flag likely leftover servers.
            return looksLikeDevServer
        }
        return !ProcessActions.isAlive(parentPID)
    }

    private var looksLikeDevServer: Bool {
        if project != nil { return true }
        let cmd = (command ?? processName).lowercased()
        let needles = [
            "node", "npm", "npx", "pnpm", "yarn", "bun", "vite", "next",
            "python", "uvicorn", "ruby", "rails", "go run", "cargo",
            "docker", "supabase", "http.server",
        ]
        return needles.contains { cmd.contains($0) }
    }

    func formattedUptime(relativeTo now: Date = Date()) -> String? {
        guard let startTime else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(startTime)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remMinutes = minutes % 60
        if hours < 48 {
            return remMinutes == 0 ? "\(hours)h" : "\(hours)h \(remMinutes)m"
        }
        let days = hours / 24
        let remHours = hours % 24
        return remHours == 0 ? "\(days)d" : "\(days)d \(remHours)h"
    }

    init(listener: ListeningPort, details: ProcessDetails?, project: ProjectInfo? = nil) {
        self.port = listener.port
        self.pid = listener.pid
        self.parentPID = details?.parentPID
        self.command = details?.command
        self.commandArguments = details?.arguments
        self.executablePath = details?.executablePath
        self.workingDirectory = details?.workingDirectory
        self.startTime = details?.startTime
        self.project = project
    }
}
