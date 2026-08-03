import Darwin
import Foundation

enum ProcessActions {

    /// Graceful stop: SIGTERM, then SIGKILL if the process is still alive
    /// after the timeout.
    static func stop(pid: Int32, timeout: Duration = .seconds(4)) async {
        guard kill(pid, SIGTERM) == 0 else { return }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            if !isAlive(pid) { return }
        }
        _ = kill(pid, SIGKILL)
    }

    static func forceKill(pid: Int32) {
        _ = kill(pid, SIGKILL)
    }

    /// kill(pid, 0) probes existence without sending a signal.
    /// EPERM means the process exists but belongs to another user.
    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
