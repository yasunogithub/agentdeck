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

    /// アプリ起動時に一度呼ぶ。クリックでセッションを開くためのデリゲートを
    /// 立てる。デリゲートは通知センターが保持しないので強参照を保つ必要が
    /// あるが、シングルトンの static let なのでこれで生き続ける。
    static func installDelegate() {
        guard bundled else { return }
        UNUserNotificationCenter.current().delegate = NotificationCenterDelegate.shared
    }

    /// セッション状態変化の通知。イベント別 ON/OFF と静寂時間の設定を反映
    /// してから出す。userInfo にセッションキーを載せ、クリックでその
    /// セッションを開けるようにする。
    func sessionEvent(_ event: NotificationEvent, body: String, sessionKey: String?) {
        let settings = NotificationSettings.shared
        guard settings.isEnabled(event), !settings.isQuietNow() else { return }
        var info: [String: Any] = [:]
        if let sessionKey { info["sessionKey"] = sessionKey }
        notify(title: event.label, body: body, sound: settings.sound(for: event), userInfo: info)
    }

    func notify(title: String, body: String, sound: NSSound.Name?, userInfo: [String: Any] = [:]) {
        guard Date().timeIntervalSince(launch) > 20 else { return }
        if let sound { NSSound(named: sound)?.play() }
        guard Self.bundled else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "AgentDeck — \(title)"
        content.body = body
        content.sound = .default
        if !userInfo.isEmpty { content.userInfo = userInfo }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// macOS 通知のクリック処理。sessionKey を持つ通知ならそのセッションを
/// 開く (HotkeyRouter 経由でボードの right panel へ)。
final class NotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationCenterDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard let key = response.notification.request.content.userInfo["sessionKey"] as? String,
              !key.isEmpty else { return }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            HotkeyRouter.shared.fire(.focusSession(key))
        }
    }

    /// フォアグラウンド中でもバナーを出す (デフォルトは出ない)。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
