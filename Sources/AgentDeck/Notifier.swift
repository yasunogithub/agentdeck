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

    /// 通知権限の状態。起動時に一度だけ要求して確定させる
    /// (毎回 requestAuthorization すると初回はダイアログ待ちで握りつぶされる)。
    private static let authState = NSLock()
    nonisolated(unsafe) private static var _authorized: Bool?

    /// アプリ起動時に一度呼ぶ。デリゲート設置 + 通知権限の要求。
    static func installDelegate() {
        guard bundled else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationCenterDelegate.shared
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            authState.lock()
            _authorized = granted
            authState.unlock()
            Self.diag("通知権限 granted=\(granted) error=\(error.map(String.init(describing:)) ?? "nil")")
            if !granted, error == nil {
                Self.diag("システム設定 > 通知 > AgentDeck で許可してください")
            }
        }
    }

    /// 診断用ファイルログ (/tmp/agentdeck-notify.log)。
    private static func diag(_ s: String) {
        let line = "\(Date()) \(s)\n"
        if let h = FileHandle(forWritingAtPath: "/tmp/agentdeck-notify.log") {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.data(using: .utf8)?.write(to: URL(fileURLWithPath: "/tmp/agentdeck-notify.log"))
        }
    }

    /// セッション状態変化の通知。イベント別 ON/OFF と静寂時間の設定を反映
    /// してから出す。userInfo にセッションキーを載せ、クリックでその
    /// セッションを開けるようにする。
    /// セッション状態変化の通知。イベント別 ON/OFF と静寂時間の設定を反映
    /// してから出す。タイトルに絵文字、本文にプロジェクト/AI最終発言を
    /// 載せて一見で内容が分かるようにする。userInfo にセッションキーを載せ、
    /// クリックでそのセッションを開けるようにする。
    func sessionEvent(_ event: NotificationEvent, session: AgentSession) {
        let settings = NotificationSettings.shared
        guard settings.isEnabled(event) else {
            Self.diag("通知スキップ (イベントOFF): \(event.label)")
            return
        }
        guard !settings.isQuietNow() else {
            Self.diag("通知スキップ (静寂時間): \(event.label)")
            return
        }
        let soundName = settings.sound(for: event)
        Self.authState.lock()
        let authorized = Self._authorized
        Self.authState.unlock()

        // リッチ表現: 絵文字 + プロジェクト/エージェント + AI最終発言スニペット
        let snippet = (session.lastAssistant ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var bodyText = "\(session.project) ・ \(session.agent)"
        if !snippet.isEmpty {
            bodyText += "\n\(snippet.prefix(140))"
        }
        let title = "\(event.emoji) \(event.label)"

        if authorized == false {
            // システム通知が使えない環境 (ad-hoc 署名では macOS 26 が拒否) は
            // アプリ内バナー + サウンドで代替する。
            if !soundName.isEmpty { NSSound(named: soundName)?.play() }
            DispatchQueue.main.async {
                ErrorCenter.shared.post("🔔 \(title) — \(session.title)", detail: session.key, playSound: false)
            }
            return
        }
        var info: [String: Any] = [:]
        info["sessionKey"] = session.key
        notify(title: title, body: "\(session.title)\n\(bodyText)", sound: soundName.isEmpty ? nil : soundName, userInfo: info)
    }

    func notify(title: String, body: String, sound: NSSound.Name?, userInfo: [String: Any] = [:]) {
        guard Date().timeIntervalSince(launch) > 20 else { return }
        if let sound { NSSound(named: sound)?.play() }
        guard Self.bundled else { return }
        Self.authState.lock()
        let authorized = Self._authorized
        Self.authState.unlock()
        guard authorized != false else {
            NSLog("AgentDeck: 通知未送信 (権限なし) — \(title)")
            return
        }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "AgentDeck — \(title)"
        content.body = body
        content.sound = .default
        if !userInfo.isEmpty { content.userInfo = userInfo }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
            if let error { NSLog("AgentDeck: 通知送信エラー: \(error)") }
        }
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
