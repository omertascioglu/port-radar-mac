import Foundation

/// A detected listening server, enriched with process details when available.
struct DevServer: Identifiable, Sendable {
    let port: Int
    let pid: Int32
    let parentPID: Int32?
    let command: String?
    let executablePath: String?
    let workingDirectory: String?
    let startTime: Date?

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

    init(listener: ListeningPort, details: ProcessDetails?) {
        self.port = listener.port
        self.pid = listener.pid
        self.parentPID = details?.parentPID
        self.command = details?.command
        self.executablePath = details?.executablePath
        self.workingDirectory = details?.workingDirectory
        self.startTime = details?.startTime
    }
}
