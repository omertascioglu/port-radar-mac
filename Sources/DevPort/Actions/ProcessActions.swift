import Darwin
import Foundation

enum KillOutcome: Sendable {
    case stopped
    case failed(String)
}

enum ProcessActions {

    /// Graceful stop: SIGTERM, then SIGKILL if still alive after the timeout.
    static func stop(pid: Int32, timeout: Duration = .seconds(4)) async -> KillOutcome {
        if !isAlive(pid) { return .stopped }

        guard kill(pid, SIGTERM) == 0 else {
            return .failed(errnoMessage(for: errno))
        }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            if !isAlive(pid) { return .stopped }
        }

        // Escalate.
        _ = kill(pid, SIGKILL)
        return await waitForDeath(pid: pid, timeout: .seconds(2))
    }

    static func forceKill(pid: Int32) async -> KillOutcome {
        if !isAlive(pid) { return .stopped }
        guard kill(pid, SIGKILL) == 0 else {
            return .failed(errnoMessage(for: errno))
        }
        return await waitForDeath(pid: pid, timeout: .seconds(2))
    }

    /// kill(pid, 0) probes existence without sending a signal.
    /// EPERM means the process exists but belongs to another user.
    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func waitForDeath(pid: Int32, timeout: Duration) async -> KillOutcome {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            if !isAlive(pid) { return .stopped }
        }
        return .failed("Process is still running")
    }

    private static func errnoMessage(for code: Int32) -> String {
        switch code {
        case EPERM: return "Permission denied"
        case ESRCH: return "Process not found"
        default: return "Could not signal process (errno \(code))"
        }
    }
}
