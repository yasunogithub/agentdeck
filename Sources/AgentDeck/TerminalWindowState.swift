import AppKit
import Foundation

/// Persists the open standalone terminal windows (the "tab" set) and reopens
/// them in the same visual order after a restart.
///
/// - Every `TerminalWindowRoot` registers/unregisters its spec as it appears
///   and disappears, so the registry always reflects what is open.
/// - `saveNow()` (called when a window closes and at termination) reorders the
///   specs by their live window frames — left→right, top→bottom — and writes
///   them to UserDefaults.
/// - `restoreAfterLaunch()` replays the saved specs through
///   `HotkeyRouter.shared.fire(.openTerminalSpec(...))`; the board's
///   `onReceive` turns them into `openWindow(id: "terminal", …)` calls.
@MainActor
final class TerminalWindowState {
    static let shared = TerminalWindowState()

    private let defaultsKey = "agentdeck.openTerminalWindowSpecs"
    /// One entry per open terminal window. Multiple windows may share a spec
    /// (e.g. two resume windows of one session), so pairs carry the
    /// windowNumber to tell them apart and to look up live frames.
    private var open: [(spec: String, windowNumber: Int)] = []
    /// ⌘⇧T 用: 直近で閉じたターミナル窓の spec 履歴 (最新が先頭、最大10件)。
    private var recentlyClosed: [String] = []

    /// 現在開いているターミナル窓の一覧 (グローバルパレットの「タブ」用)。
    var openSpecs: [(spec: String, windowNumber: Int)] { open }

    func register(spec: String, windowNumber: Int) {
        if let idx = open.firstIndex(where: { $0.windowNumber == windowNumber }) {
            open[idx].spec = spec
        } else {
            open.append((spec, windowNumber))
        }
    }

    /// A window closed (onDisappear of its TerminalWindowRoot). Only entries
    /// whose window is actually gone are dropped — the same spec may still be
    /// open in another window. The visible order is re-saved right away so a
    /// crash can't resurrect closed tabs. Dropped specs feed the ⌘⇧T
    /// reopen-last stack.
    func unregister(spec: String) {
        let before = open
        open.removeAll { pair in
            NSApp.window(withWindowNumber: pair.windowNumber) == nil
        }
        if open.count != before.count {
            saveNow()
            let closed = before.filter { pair in
                !open.contains { $0.windowNumber == pair.windowNumber }
            }.map(\.spec)
            for s in closed {
                recentlyClosed.insert(s, at: 0)
            }
            if recentlyClosed.count > 10 {
                recentlyClosed.removeLast(recentlyClosed.count - 10)
            }
        }
    }

    /// ⌘⇧T — reopen the most recently closed terminal window (browser-style,
    /// the stack is consumed like closed tabs). Sessions that no longer exist
    /// are skipped; returns false when nothing could be reopened.
    @discardableResult
    func reopenLast() -> Bool {
        guard let spec = recentlyClosed.first else { return false }
        recentlyClosed.removeFirst()
        guard Self.isRestorable(spec) else { return reopenLast() }
        HotkeyRouter.shared.fire(.openTerminalSpec(spec))
        return true
    }

    /// Persist specs in current screen order. Windows already closed are
    /// skipped (their windowNumber no longer resolves).
    func saveNow() {
        let live = open.compactMap { pair -> (spec: String, frame: NSRect)? in
            guard let window = NSApp.window(withWindowNumber: pair.windowNumber) else { return nil }
            return (pair.spec, window.frame)
        }
        let ordered = live.sorted { a, b in
            if a.frame.minY != b.frame.minY { return a.frame.minY > b.frame.minY }
            return a.frame.minX < b.frame.minX
        }
        UserDefaults.standard.set(ordered.map(\.spec), forKey: defaultsKey)
    }

    /// 指定セッションのターミナル窓が既に開いている場合、その NSWindow を
    /// 返す。spec 形式 (resume / comment: / attach: / handoff:) が違っても
    /// 同じセッションなら同じ窓とみなす — 復元・再オープン時の重複タブを
    /// 防ぐための 1 セッション = 1 窓 の判定。
    func existingWindow(forSession key: String) -> NSWindow? {
        for pair in open {
            guard TerminalWindowState.sessionKey(from: pair.spec) == key else { continue }
            if let w = NSApp.window(withWindowNumber: pair.windowNumber), w.isVisible {
                return w
            }
        }
        return nil
    }

    /// Reopen the saved window set after launch. Specs whose session isn't in
    /// the store yet are retried for a few seconds (the startup scan loads
    /// sessions asynchronously); sessions that never appear are dropped.
    /// Deduplication is per *session key*, not per raw spec — the same session
    /// saved once as `resume` and once as `attach:…` must not reopen twice.
    func restoreAfterLaunch() {
        let saved = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        guard !saved.isEmpty else { return }
        var seen = Set<String>()
        var pending: [String] = []
        for spec in saved {
            let dedupeKey = self.dedupeKey(for: spec)
            guard seen.insert(dedupeKey).inserted else { continue }
            pending.append(spec)
        }
        var attempts = 0
        func attempt() {
            attempts += 1
            let ready = pending.filter { spec in
                // リトライ中にユーザーが手動で開いたセッションは復元しない。
                if existingWindow(forSession: Self.sessionKey(from: spec)) != nil { return true }
                guard Self.isRestorable(spec) else { return false }
                HotkeyRouter.shared.fire(.openTerminalSpec(spec))
                return true
            }
            pending.removeAll { ready.contains($0) }
            guard !pending.isEmpty, attempts < 10 else { return }
            // Startup scan still filling the store — try again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { attempt() }
        }
        attempt()
    }

    /// どの形式の spec でも「セッションキー」に丸めて重複判定する。
    /// bare: はパスそのものをキーに、handoff: は「新規セッション」なので
    /// 常に別窓として扱う (dedupe しない = キーに spec 全体を使う)。
    private func dedupeKey(for spec: String) -> String {
        if spec.hasPrefix("bare:") {
            return spec
        }
        if spec.hasPrefix("handoff:") {
            return "new:\(spec)"  // ハンドオフは毎回新規セッション → 重複排除しない
        }
        return Self.sessionKey(from: spec)
    }

    /// A saved spec can be reopened once either the session is in the store
    /// (scan-derived) or it's a bare terminal that needs no stored session.
    static func isRestorable(_ spec: String) -> Bool {
        if spec.hasPrefix("bare:") { return true }
        return SessionStore.shared.sessions.contains { $0.key == sessionKey(from: spec) }
    }

    /// Same spec→key parsing as `TerminalWindowRoot.key`: the session key is
    /// the first line after any mode prefix.
    static func sessionKey(from spec: String) -> String {
        var s = spec
        if s.hasPrefix("handoffto:"), let nl = s.firstIndex(of: "\n") {
            s = String(s[s.index(after: nl)...])
        }
        for prefix in ["handoff:", "comment:", "attach:"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        if let nl = s.firstIndex(of: "\n") { s = String(s[..<nl]) }
        return s
    }
}