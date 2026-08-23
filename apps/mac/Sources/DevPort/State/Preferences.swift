// Modification notice: Changed in 2026 for the local AI and optional Ollama fallback contribution.
import Foundation
import Observation

/// User preferences persisted in UserDefaults.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences(defaults: .standard)

    private enum Key {
        static let pollingInterval = "pollingIntervalSeconds"
        static let notifications = "notificationsEnabled"
        static let hideSystem = "hideSystemProcesses"
        static let portMin = "portRangeMin"
        static let portMax = "portRangeMax"
        static let allowlist = "processAllowlist"
        static let preferredIDE = "preferredIDEBundleID"
        static let askAboutProcess = "askAboutProcessEnabled"
        static let localAIProvider = "localAIProvider"
        static let ollamaModel = "ollamaModel"
    }

    private let defaults: UserDefaults

    /// Suppresses SMAppService writes while syncing from system status.
    private var suppressLaunchAtLoginWrite = false

    /// Default matches the scanner's original interval.
    var pollingIntervalSeconds: Double {
        didSet { defaults.set(pollingIntervalSeconds, forKey: Key.pollingInterval) }
    }

    /// On by default — user can turn off.
    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notifications) }
    }

    /// Off by default — system rows stay visible until the user opts to hide them.
    var hideSystemProcesses: Bool {
        didSet { defaults.set(hideSystemProcesses, forKey: Key.hideSystem) }
    }

    /// Launch Port Radar when the user logs in. Backed by `SMAppService`, not UserDefaults.
    var launchAtLogin: Bool {
        didSet {
            guard !suppressLaunchAtLoginWrite else { return }
            if let message = LaunchAtLogin.setEnabled(launchAtLogin) {
                suppressLaunchAtLoginWrite = true
                launchAtLogin = LaunchAtLogin.isEnabled
                suppressLaunchAtLoginWrite = false
                launchAtLoginError = message
            } else {
                launchAtLoginError = nil
            }
        }
    }

    /// Last error from enabling/disabling launch at login, if any.
    var launchAtLoginError: String?

    var portRangeMin: Int {
        didSet { defaults.set(portRangeMin, forKey: Key.portMin) }
    }

    var portRangeMax: Int {
        didSet { defaults.set(portRangeMax, forKey: Key.portMax) }
    }

    /// Comma/space-separated process name needles. Empty = show all.
    var processAllowlist: String {
        didSet { defaults.set(processAllowlist, forKey: Key.allowlist) }
    }

    /// Bundle ID of the preferred editor (Cursor, VS Code, Zed, …).
    var preferredIDEBundleID: String {
        didSet { defaults.set(preferredIDEBundleID, forKey: Key.preferredIDE) }
    }

    /// Show “Ask about process” (local AI). On by default; turn off if unsupported or unwanted.
    var askAboutProcessEnabled: Bool {
        didSet { defaults.set(askAboutProcessEnabled, forKey: Key.askAboutProcess) }
    }

    var localAIProviderPreference: LocalAIProviderPreference {
        didSet {
            defaults.set(
                localAIProviderPreference.rawValue,
                forKey: Key.localAIProvider
            )
        }
    }

    var ollamaModelID: String {
        didSet { defaults.set(ollamaModelID, forKey: Key.ollamaModel) }
    }

    var preferredIDEName: String {
        IDEDetector.displayName(for: preferredIDEBundleID) ?? "Editor"
    }

    var allowlistTokens: [String] {
        processAllowlist
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { String($0).lowercased() }
            .filter { !$0.isEmpty }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults

        let stored = defaults.double(forKey: Key.pollingInterval)
        pollingIntervalSeconds = stored > 0 ? stored : 2.5

        if defaults.object(forKey: Key.notifications) == nil {
            notificationsEnabled = true
        } else {
            notificationsEnabled = defaults.bool(forKey: Key.notifications)
        }

        if defaults.object(forKey: Key.askAboutProcess) == nil {
            askAboutProcessEnabled = true
        } else {
            askAboutProcessEnabled = defaults.bool(forKey: Key.askAboutProcess)
        }

        hideSystemProcesses = defaults.bool(forKey: Key.hideSystem)

        let minStored = defaults.integer(forKey: Key.portMin)
        let maxStored = defaults.integer(forKey: Key.portMax)
        portRangeMin = minStored > 0 ? minStored : 1
        portRangeMax = maxStored > 0 ? maxStored : 65535
        processAllowlist = defaults.string(forKey: Key.allowlist) ?? ""

        let savedIDE = defaults.string(forKey: Key.preferredIDE) ?? ""
        let knownInstalled = IDEDetector.installed().map(\.bundleIdentifier)
        if !savedIDE.isEmpty, knownInstalled.contains(savedIDE) {
            preferredIDEBundleID = savedIDE
        } else {
            preferredIDEBundleID = IDEDetector.preferredDefault()?.bundleIdentifier ?? ""
        }

        localAIProviderPreference = LocalAIProviderPreference.persistedValue(
            defaults.string(forKey: Key.localAIProvider)
        )
        ollamaModelID = defaults.string(forKey: Key.ollamaModel) ?? ""

        suppressLaunchAtLoginWrite = true
        launchAtLogin = LaunchAtLogin.isEnabled
        suppressLaunchAtLoginWrite = false
        launchAtLoginError = nil
    }

    /// Re-read Login Items status (e.g. after user changes it in System Settings).
    func refreshLaunchAtLogin() {
        suppressLaunchAtLoginWrite = true
        launchAtLogin = LaunchAtLogin.isEnabled
        suppressLaunchAtLoginWrite = false
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
