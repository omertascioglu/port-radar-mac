import Foundation
import UserNotifications

enum PortNotifier {
    static func requestPermissionIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    static func notifyNewPort(port: Int, processName: String) {
        let content = UNMutableNotificationContent()
        content.title = "New port listening"
        content.body = "\(processName) on localhost:\(port)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "devport.new.\(port).\(processName).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
