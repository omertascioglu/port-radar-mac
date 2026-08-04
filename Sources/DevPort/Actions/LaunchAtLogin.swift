import Foundation
import ServiceManagement

/// Registers Port Radar as a Login Item via `SMAppService` (macOS 13+).
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns an error message when the change could not be applied.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                if SMAppService.mainApp.status == .enabled { return nil }
                try SMAppService.mainApp.register()
            } else {
                switch SMAppService.mainApp.status {
                case .notRegistered:
                    return nil
                default:
                    try SMAppService.mainApp.unregister()
                }
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
