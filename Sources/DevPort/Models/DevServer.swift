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
