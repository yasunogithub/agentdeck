import Foundation
import Combine

/// 通知イベントの種類。設定 UI と Notifier の両方から参照する。
enum NotificationEvent: String, CaseIterable, Identifiable {
    case waiting   // 入力待ち
    case done      // 完了
    case failed    // 失敗
    case prMerged  // PR merged
    var id: String { rawValue }

    var label: String {
        switch self {
        case .waiting: return "入力待ち"
        case .done: return "完了"
        case .failed: return "失敗"
        case .prMerged: return "PR merged"
        }
    }

    /// 通知タイトルの先頭に付ける絵文字 (一見で種別が分かるように)。
    var emoji: String {
        switch self {
        case .waiting: return "💬"
        case .done: return "✅"
        case .failed: return "❌"
        case .prMerged: return "🎉"
        }
    }

    /// 既定サウンド (NSSound 名)。
    var defaultSound: String {
        switch self {
        case .waiting: return "Ping"
        case .done: return "Glass"
        case .failed: return "Sosumi"
        case .prMerged: return "Pop"
        }
    }
}

/// 設定の実体。Codable でまとめて UserDefaults に永続化する。
struct NotificationPrefs: Codable, Equatable {
    // イベント rawValue → ON/OFF。未記録 = ON。
    var enabled: [String: Bool] = [:]
    // イベント rawValue → NSSound 名。未記録 = 既定サウンド。
    var sounds: [String: String] = [:]
    var quietEnabled = false
    /// 静寂開始・終了の時 (0–23)。22 → 7 なら 22:00〜翌7:00。
    var quietStartHour = 22
    var quietEndHour = 7

    func isEnabled(_ e: NotificationEvent) -> Bool { enabled[e.rawValue] ?? true }
    func sound(for e: NotificationEvent) -> String { sounds[e.rawValue] ?? e.defaultSound }
}

/// 通知のユーザー設定。UI (メインスレッド) からの書き込みと、Notifier
/// (任意スレッド) からの読み取りが交差するのでロックで守る。UI への
/// 再描画通知は revision の @Published で行う。
final class NotificationSettings: ObservableObject, @unchecked Sendable {
    static let shared = NotificationSettings()

    /// UI 再描画用カウンタ。update() で増える。
    @Published var revision = 0

    private let lock = NSLock()
    private var _prefs = NotificationSettings.load()
    private static let defaultsKey = "agentdeck.notificationPrefs"

    private static func load() -> NotificationPrefs {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let p = try? JSONDecoder().decode(NotificationPrefs.self, from: data) else {
            return NotificationPrefs()
        }
        return p
    }

    var prefs: NotificationPrefs {
        lock.lock(); defer { lock.unlock() }
        return _prefs
    }

    /// 設定を変更する (Settings UI = メインスレッドから呼ぶ)。
    func update(_ mutate: (inout NotificationPrefs) -> Void) {
        lock.lock()
        mutate(&_prefs)
        let snapshot = _prefs
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
        revision += 1
    }

    // MARK: - Notifier から使う読み取り系

    func isEnabled(_ e: NotificationEvent) -> Bool { prefs.isEnabled(e) }
    func sound(for e: NotificationEvent) -> String { prefs.sound(for: e) }

    /// 今が静寂時間内か。開始==終了は無効 (静寂なし) 扱い。
    func isQuietNow(_ now: Date = Date()) -> Bool {
        let p = prefs
        guard p.quietEnabled, p.quietStartHour != p.quietEndHour else { return false }
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: now)
        let t = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let s = p.quietStartHour * 60
        let e = p.quietEndHour * 60
        if s < e { return t >= s && t < e }
        return t >= s || t < e  // 日をまたぐ (22→7)
    }

    /// サウンド選択肢 (NSSound 名)。
    static let soundChoices = [
        "", "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]
}
