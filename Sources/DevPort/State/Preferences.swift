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

    private init() {
        let stored = UserDefaults.standard.double(forKey: Key.pollingInterval)
        pollingIntervalSeconds = stored > 0 ? stored : 2.5

        if UserDefaults.standard.object(forKey: Key.notifications) == nil {
            notificationsEnabled = true
        } else {
            notificationsEnabled = UserDefaults.standard.bool(forKey: Key.notifications)
        }

        hideSystemProcesses = UserDefaults.standard.bool(forKey: Key.hideSystem)
    }

    /// Safe to call from the scanner actor — reads UserDefaults directly.
    nonisolated static func currentPollingInterval() -> Duration {
        let stored = UserDefaults.standard.double(forKey: Key.pollingInterval)
        let seconds = stored > 0 ? stored : 2.5
        return .seconds(seconds)
    }
}
