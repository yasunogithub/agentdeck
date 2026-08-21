import AppKit
import Foundation

/// アプリ全窓から開ける openWindow の入口。SwiftUI の openWindow は
/// Commands/View の Environment でしか取れないため、DashboardCommands が
/// 起動時にここへクロージャを差し込む。キーモニタ (AppKit 側) から呼ぶ。
enum GlobalWindowActions {
    nonisolated(unsafe) static var openDashboard: (() -> Void)?
}

/// ターミナル窓などボード以外から ⌘K したときのパレット項目。
/// ボードの選択状態に依存しないグローバルなカタログ:
/// 開いているタブ / セッション履歴 / GitHub PR / Trello カード / vault メモ。
@MainActor
enum GlobalPaletteCatalog {

    static func items() -> [PaletteItem] {
        var items: [PaletteItem] = []
        let store = SessionStore.shared

        // Trello/GitHub URL の抽出 (キャッシュ済みなら即帰る)。ヒットは
        // 次回のパレット表示から載る。
        UrlScanner.shared.rescanIfNeeded()

        // 1. 開いているターミナル窓 (タブ名であたり、前面に出す)
        for w in TerminalWindowState.shared.openSpecs {
            let label = Self.tabLabel(for: w.spec)
            items.append(PaletteItem(
                title: "タブ: \(label)",
                subtitle: "開いているターミナルを前面に (\(w.spec))",
                icon: "macwindow.on.rectangle",
                tint: .indigo,
                action: {
                    if let win = NSApp.window(withWindowNumber: w.windowNumber) {
                        win.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            ))
        }

        // 2. セッション履歴 (最近のもの順)。subtitle に最後のAI発言を添え、
        //    「何をしていたセッションか」を検索・判別できるようにする。
        let recent = store.sessions.sorted { $0.lastActivity > $1.lastActivity }.prefix(80)
        for s in recent {
            let snippet = (s.lastAssistant ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            let sub = "\(s.agent) ・ \(s.project)" + (snippet.isEmpty ? "" : " ・ \(String(snippet.prefix(90)))")
            items.append(PaletteItem(
                title: s.title,
                subtitle: sub,
                icon: Self.stateIcon(s.state),
                tint: .blue,
                action: { HotkeyRouter.shared.fire(.focusSession(s.key)) }
            ))
        }

        // 3. GitHub PR (enricher が把握している PR)
        for s in store.sessions where s.prNumber != nil {
            items.append(PaletteItem(
                title: "GitHub #\(s.prNumber!) — \(s.title)",
                subtitle: "\(s.prState ?? "?") ・ \(s.project)",
                icon: "github",
                tint: .purple,
                action: { RepoTools.openPR(s) }
            ))
        }

        // 4. Trello カード (トランスクリプトから抽出)
        for hit in UrlScanner.shared.trelloHits {
            items.append(PaletteItem(
                title: "Trello: \(hit.sessionTitle)",
                subtitle: hit.url,
                icon: "checklist",
                tint: .mint,
                action: { NSWorkspace.shared.open(URL(string: hit.url)!) }
            ))
        }

        // 5. vault メモ (日次蒸留ログなどの「資料」)
        for note in UrlScanner.vaultNotes().prefix(20) {
            items.append(PaletteItem(
                title: "メモ: \(note.name)",
                subtitle: note.path,
                icon: "doc.text",
                tint: .gray,
                action: { NSWorkspace.shared.open(note.url) }
            ))
        }

        return items
    }

    private static func tabLabel(for spec: String) -> String {
        let store = SessionStore.shared
        var s = spec
        if s.hasPrefix("bare:") {
            return "新規ターミナル — " + ((s.dropFirst(5) as NSString).lastPathComponent)
        }
        for p in ["handoff:", "comment:", "attach:", "handoffto:"] where s.hasPrefix(p) {
            s = String(s.dropFirst(p.count))
        }
        if let nl = s.firstIndex(of: "\n") { s = String(s[..<nl]) }
        if let sess = store.sessions.first(where: { $0.key == s }) {
            return sess.title
        }
        return s
    }

    private static func stateIcon(_ state: SessionState) -> String {
        switch state {
        case .running: return "circle.dotted"
        case .waiting: return "ellipsis.bubble"
        case .done: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        default: return "circle"
        }
    }
}

/// トランスクリプトから Trello / GitHub の URL を抜き出すスキャナ。
/// mtime 見込みキャッシュ付き (StatsCollector と同方式)。検索は雑でも
/// 高速に、パレットの fuzzy 検索にURL文字列ごと渡す。
final class UrlScanner: @unchecked Sendable {
    static let shared = UrlScanner()

    struct Hit: Identifiable, Sendable, Equatable {
        let url: String
        let sessionTitle: String
        var id: String { url }
    }

    struct Entry: Codable {
        var mtime: Double = 0
        var trello: [String] = []
        var github: [String] = []
    }

    private let lock = NSLock()
    private var cache: [String: Entry] = [:]
    private(set) var trelloHits: [Hit] = []
    private(set) var githubHits: [Hit] = []
    private var lastScan = Date.distantPast
    private var scanning = false

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("url-cache.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.cacheURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            cache = decoded
        }
    }

    /// vault (Digest の蒸留ログ) の Markdown 一覧。
    struct Note: Sendable {
        let name: String
        let path: String
        let url: URL
    }

    static func vaultNotes() -> [Note] {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("dev/agentdeck/vault")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }.map {
            Note(name: $0.deletingPathExtension().lastPathComponent, path: $0.path, url: $0)
        }.sorted { $0.name > $1.name }
    }

    /// パレットが開かれるたびに呼ぶ。10分以内の再スキャンはスキップ。
    func rescanIfNeeded() {
        lock.lock()
        if scanning, Date().timeIntervalSince(lastScan) < 600 {
            lock.unlock()
            return
        }
        scanning = true
        lastScan = Date()
        lock.unlock()

        let metas: [(path: String, title: String)] = MainActor.assumeIsolated {
            SessionStore.shared.sessions.compactMap { s in
                guard let p = s.transcriptPath, !p.isEmpty else { return nil }
                return (p, s.title)
            }
        }
        Task.detached(priority: .utility) { [weak self] in
            self?.scan(metas)
        }
    }

    private func scan(_ metas: [(path: String, title: String)]) {
        let fm = FileManager.default
        var trello: [Hit] = []
        var github: [Hit] = []
        var seen = Set<String>()
        var dirty = false

        for meta in metas {
            lock.lock()
            let cached = cache[meta.path]
            lock.unlock()
            let attrs = try? fm.attributesOfItem(atPath: meta.path)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            var entry = cached
            if entry == nil || entry!.mtime != mtime {
                entry = Self.parse(path: meta.path, mtime: mtime)
                if let e = entry {
                    lock.lock()
                    cache[meta.path] = e
                    lock.unlock()
                    dirty = true
                }
            }
            guard let e = entry else { continue }
            for u in e.trello where !seen.contains(u) {
                seen.insert(u)
                trello.append(Hit(url: u, sessionTitle: meta.title))
            }
            for u in e.github where !seen.contains(u) {
                seen.insert(u)
                github.append(Hit(url: u, sessionTitle: meta.title))
            }
        }
        if dirty {
            lock.lock()
            let snapshot = cache
            lock.unlock()
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: Self.cacheURL, options: .atomic)
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.trelloHits = trello
            self.githubHits = github
            self.lock.lock()
            self.scanning = false
            self.lock.unlock()
        }
    }

    private static func parse(path: String, mtime: Double) -> Entry? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? Int) ?? 0
        guard size > 0, size < 16_000_000,  // 巨大ファイルはスキップ
              let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        var entry = Entry(mtime: mtime)
        entry.trello = Self.matches(in: text, pattern: #"https://trello\.com/c/[A-Za-z0-9]+"#)
        entry.github = Self.matches(
            in: text,
            pattern: #"https://github\.com/[A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+/(?:pull|issues)/\d+"#
        )
        return entry
    }

    private static func matches(in text: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return Set(re.matches(in: text, range: NSRange(location: 0, length: ns.length)))
            .map { ns.substring(with: $0.range) }
            .sorted()
    }
}
