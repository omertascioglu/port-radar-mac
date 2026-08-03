import Foundation
import Observation

/// User preferences persisted in UserDefaults.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    private enum Key {
        static let pollingInterval = "pollingIntervalSeconds"
        static let notifications = "notificationsEnabled"
        static let hideSystem = "hideSystemProcesses"
        static let portMin = "portRangeMin"
        static let portMax = "portRangeMax"
        static let allowlist = "processAllowlist"
    }

    /// Default matches the scanner's original interval.
    var pollingIntervalSeconds: Double {
        didSet { UserDefaults.standard.set(pollingIntervalSeconds, forKey: Key.pollingInterval) }
    }

    /// On by default — user can turn off.
    var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: Key.notifications) }
    }

    /// Off by default — system rows stay visible until the user opts to hide them.
    var hideSystemProcesses: Bool {
        didSet { UserDefaults.standard.set(hideSystemProcesses, forKey: Key.hideSystem) }
    }

    var portRangeMin: Int {
        didSet { UserDefaults.standard.set(portRangeMin, forKey: Key.portMin) }
    }

    var portRangeMax: Int {
        didSet { UserDefaults.standard.set(portRangeMax, forKey: Key.portMax) }
    }

    /// Comma/space-separated process name needles. Empty = show all.
    var processAllowlist: String {
        didSet { UserDefaults.standard.set(processAllowlist, forKey: Key.allowlist) }
    }

    var allowlistTokens: [String] {
        processAllowlist
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { String($0).lowercased() }
            .filter { !$0.isEmpty }
    }

    private init() {
        let stored = UserDefaults.standard.double(forKey: Key.pollingInterval)
        pollingIntervalSeconds = stored > 0 ? stored : 2.5

        if UserDefaults.standard.object(forKey: Key.notifications) == nil {
            notificationsEnabled = true
        } else {
            notificationsEnabled = UserDefaults.standard.bool(forKey: Key.notifications)
        }

        hideSystemProcesses = UserDefaults.standard.bool(forKey: Key.hideSystem)

        let minStored = UserDefaults.standard.integer(forKey: Key.portMin)
        let maxStored = UserDefaults.standard.integer(forKey: Key.portMax)
        portRangeMin = minStored > 0 ? minStored : 1
        portRangeMax = maxStored > 0 ? maxStored : 65535
        processAllowlist = UserDefaults.standard.string(forKey: Key.allowlist) ?? ""
    }

    func matchesFilters(_ server: DevServer) -> Bool {
        if hideSystemProcesses && server.isSystemProcess { return false }
        let lo = min(portRangeMin, portRangeMax)
        let hi = max(portRangeMin, portRangeMax)
        if server.port < lo || server.port > hi { return false }
        let tokens = allowlistTokens
        if !tokens.isEmpty {
            let haystack = "\(server.processName) \(server.command ?? "")".lowercased()
            if !tokens.contains(where: { haystack.contains($0) }) { return false }
        }
        return true
    }

    /// Safe to call from the scanner actor — reads UserDefaults directly.
    nonisolated static func currentPollingInterval() -> Duration {
        let stored = UserDefaults.standard.double(forKey: Key.pollingInterval)
        let seconds = stored > 0 ? stored : 2.5
        return .seconds(seconds)
    }
}
