import Foundation
import os

let scannerLog = Logger(subsystem: "com.sebsol.DevPort", category: "scanner")

/// One listening TCP socket: a port bound by a process.
/// IPv4/IPv6 duplicates for the same (port, pid) collapse via Hashable.
struct ListeningPort: Hashable, Sendable {
    let port: Int
    let pid: Int32
}

enum ScanError: Error {
    case lsofLaunchFailed(Error)
}

enum PortScanner {

    /// Snapshot of all listening TCP ports visible to the current user.
    /// Uses `lsof -F` field output (one field per line) for robust parsing.
    static func scan() throws -> Set<ListeningPort> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-iTCP", "-sTCP:LISTEN", "-P", "-n", "-F", "pn"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw ScanError.lsofLaunchFailed(error)
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // lsof exits non-zero for e.g. inaccessible processes while still
        // printing valid output, so parse whatever we got instead of failing.
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return parse(text)
    }

    /// Parses `lsof -F pn` output: `p<pid>` starts a process section,
    /// each `n<addr>` line is a socket name like `127.0.0.1:5173` or `*:3000`.
    static func parse(_ output: String) -> Set<ListeningPort> {
        var result: Set<ListeningPort> = []
        var currentPID: Int32?

        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = line.dropFirst()
            switch tag {
            case "p":
                currentPID = Int32(value)
            case "n":
                guard let pid = currentPID,
                      let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...])
                else { continue }
                result.insert(ListeningPort(port: port, pid: pid))
            default:
                break
            }
        }
        return result
    }
}
