import AppKit
import UserNotifications

/// State-transition alerts: sound + macOS notification. Fails open
/// (unbundled binary may not show banners; sound always works).
/// Silent during the first 20s so startup scans never spam.
final class Notifier: Sendable {
    static let shared = Notifier()
    private let launch = Date()

    /// UNUserNotificationCenter throws on unbundled (SPM) binaries — sound only then.
    private static let bundled = Bundle.main.bundleURL.pathExtension == "app"

    func notify(title: String, body: String, sound: NSSound.Name?) {
        guard Date().timeIntervalSince(launch) > 20 else { return }
        if let sound { NSSound(named: sound)?.play() }
        guard Self.bundled else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "AgentDeck — \(title)"
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
