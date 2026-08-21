import Foundation
import SwiftUI

enum SessionState: String, Codable {
    case running
    case waiting
    case done
    case failed
    case idle

    var color: Color {
        switch self {
        case .running: .blue
        case .waiting: .yellow
        case .done: .green
        case .failed: .red
        case .idle: .gray
        }
    }

    var label: String {
        switch self {
        case .running: "実行中"
        case .waiting: "入力待ち"
        case .done: "完了"
        case .failed: "失敗"
        case .idle: "アイドル"
        }
    }

    /// Colored dot for window/tab titles: the same color coding as cards.
    var dot: String {
        switch self {
        case .running: "🔵"
        case .waiting: "🟡"
        case .done: "🟢"
        case .failed: "🔴"
        case .idle: "⚪️"
        }
    }

    var sortRank: Int {
        switch self {
        case .waiting: 0
        case .running: 1
        case .failed: 2
        case .done: 3
        case .idle: 4
        }
    }
}

struct AgentEvent: Codable {
    var agent: String
    var sessionId: String
    var event: String
    var project: String?
    var cwd: String?
    var title: String?
    var ts: Date?
}

struct AgentSession: Identifiable, Sendable {
    var id: String { key }
    let key: String
    var sessionId: String {
        let parts = key.split(separator: ":", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : key
    }
    /// Short, collision-resistant id for card display. opencode2 ids share a
    /// long "ses_0304..." prefix and DeepSeek Harness ids a "session-<uuid>"
    /// prefix, so leading truncation made distinct sessions look identical;
    /// the trailing/after-prefix bytes differ instead.
    var shortID: String {
        if sessionId.hasPrefix("ses_") { return String(sessionId.suffix(8)) }
        if sessionId.hasPrefix("session-") {
            return String(sessionId.dropFirst("session-".count).prefix(8))
        }
        return String(sessionId.prefix(8))
    }
    var agent: String
    var project: String
    var title: String
    var state: SessionState
    var lastActivity: Date
    var lastEvent: String
    var lastEventTs: Date = .distantPast
    var cwd: String?
    var transcriptPath: String?
    var branch: String?
    var prState: String?
    var prNumber: Int?
    var lastAssistant: String?
    var firstPrompt: String?
    var startedAt: Date?
    var hasWorktree = false
    /// pi deck extension ground truth (status.json): working | waiting | closed
    /// plus the time it was written. When present it beats transcript
    /// staleness for state and activity.
    var liveStatus: String?
    var liveStatusAt: Date?
    /// tmux session name (qwen-tmux) when one is live for this cwd — enables
    /// real-time mirrored attach instead of --resume.
    var tmuxSession: String?
    /// SubAgent セッションの親キー (opencode2 の parent_id)。ボードでは
    /// 親カードに内包し、既定で折りたたんで表示する。
    var parentID: String?

    /// Search matches everything a card shows, so what you see is what you can find.
    func matches(_ q: String) -> Bool {
        title.localizedCaseInsensitiveContains(q)
            || project.localizedCaseInsensitiveContains(q)
            || agent.localizedCaseInsensitiveContains(q)
            || (branch?.localizedCaseInsensitiveContains(q) ?? false)
            || (prNumber.map { String($0).contains(q) } ?? false)
            || (lastAssistant?.localizedCaseInsensitiveContains(q) ?? false)
            || sessionId.localizedCaseInsensitiveContains(q)
    }
}

extension AgentSession {
    /// Short, human-readable repo/folder name for cards and panel headers:
    /// the last path component of cwd (or project), so
    /// "/Users/…/dev/em-roadster-3" reads "em-roadster-3".
    var repoName: String {
        let raw = (cwd?.isEmpty == false) ? cwd! : project
        guard raw.hasPrefix("/") else { return project }
        let parts = raw.split(separator: "/")
        return parts.isEmpty ? project : String(parts[parts.count - 1])
    }
}

@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    private let manualArchiveDefaultsKey = "agentDeck.manualArchivedSessionKeys"
    private let manualRestoreDefaultsKey = "agentDeck.manualRestoredSessionKeys"
    private var manuallyArchived: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "agentDeck.manualArchivedSessionKeys") ?? []
    )
    private var manuallyRestored: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "agentDeck.manualRestoredSessionKeys") ?? []
    )
    /// 自動アーカイブされたキー (autoArchiveFinished のみ追加。再起動時は毎回
    /// 再導出されるので永続化しない)。「アーカイブなのに会話が続いている」が
    /// 起きたとき、手動アーカイブと区別して解除する手がかりになる。
    private var autoArchived: Set<String> = []

    /// ボードのデフォルト表示窓: 今日 + 昨日。固定時間幅 (4h/8h/24h) だと時間帯に
    /// よって「前日が最終更新」のセッションが欠けるため、暦日ベース (昨日 00:00)
    /// で切る。それより前は アーカイブ か 履歴表示 (⌘⇧H) で。
    nonisolated static var boardCutoff: Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(-24 * 3600)
    }

    /// Manual archive state supplements the date-based archive. A restored
    /// session stays on the board after it becomes older than the cutoff.
    func isArchived(_ session: AgentSession) -> Bool {
        if manuallyArchived.contains(session.key) { return true }
        if manuallyRestored.contains(session.key) { return false }
        return session.lastActivity < Self.boardCutoff
    }

    /// SubAgent セッションか (親がボードに表示されている場合 = 親カードに
    /// 内包される)。ボード以外のパレット・ダッシュボード・統計でも
    /// トップレベル表示からは除外する。親が居ない/アーカイブ済みの子は
    /// 行き場がないので独立扱い。
    func isContainedSubagent(_ s: AgentSession) -> Bool {
        guard let pid = s.parentID else { return false }
        guard let parent = sessions.first(where: { $0.key == pid }) else { return false }
        return shouldShowOnBoard(parent)
    }

    func shouldShowOnBoard(_ session: AgentSession) -> Bool {
        guard !manuallyArchived.contains(session.key) else { return false }
        return showHistory || session.lastActivity >= Self.boardCutoff || manuallyRestored.contains(session.key)
    }

    func archive(_ key: String) {
        autoArchived.remove(key)
        manuallyRestored.remove(key)
        manuallyArchived.insert(key)
        persistArchiveState()
        publishSoon()
    }

    func unarchive(_ key: String) {
        autoArchived.remove(key)
        manuallyArchived.remove(key)
        manuallyRestored.insert(key)
        persistArchiveState()
        publishSoon()
    }

    /// 会話が再開したセッションのアーカイブを解除する。自動・手動どちらの
    /// アーカイブでも、「アーカイブされたものがまた動き始めたのに見えない」
    /// 状態を作らないための処理 (ボードに戻って見えるようにする)。
    private func unarchiveOnResume(_ key: String) {
        guard manuallyArchived.remove(key) != nil || autoArchived.remove(key) != nil else { return }
        persistArchiveState()
    }

    private func persistArchiveState() {
        UserDefaults.standard.set(Array(manuallyArchived), forKey: manualArchiveDefaultsKey)
        UserDefaults.standard.set(Array(manuallyRestored), forKey: manualRestoreDefaultsKey)
    }

    /// "たった今 / 3分前 / 2時間前 / 3日前"。Text(_, style: .relative) は
    /// TimelineSchedule を毎フレーム再評価して UpdateCycle ドライバが
    /// 止まらず CPU を食うため、ボードの publish (5〜10s周期) で再計算される
    /// 静的文字列に置き換える。
    static func relativeAge(_ date: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(date)))
        if s < 60 { return "たった今" }
        if s < 3600 { return "\(s / 60)分前" }
        if s < 86400 { return "\(s / 3600)時間前" }
        return "\(s / 86400)日前"
    }

    // Plain vars + throttled publish: hook events stream in per agent turn and
    // publishing each one made the board flicker/re-sort constantly.
    private(set) var sessions: [AgentSession] = []
    private(set) var eventCount = 0
    @Published var showHistory = false

    private var publishScheduled = false
    func publishSoon() {
        guard !publishScheduled else { return }
        publishScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.publishScheduled else { return }
                self.publishScheduled = false
                self.objectWillChange.send()
            }
        }
    }

    var sortedSessions: [AgentSession] {
        let cutoff = SessionStore.boardCutoff
        return sessions
            .filter { showHistory || $0.lastActivity >= cutoff }
            .sorted { a, b in
                if a.state.sortRank != b.state.sortRank {
                    return a.state.sortRank < b.state.sortRank
                }
                // Stable within a rank: startedAt doesn't churn per event.
                return (a.startedAt ?? a.lastActivity) > (b.startedAt ?? b.lastActivity)
            }
    }

    func apply(_ event: AgentEvent) {
        eventCount += 1
        let key = "\(event.agent):\(event.sessionId)"
        let now = event.ts ?? Date()
        let newState = stateFor(event: event.event)

        if let idx = sessions.firstIndex(where: { $0.key == key }) {
            if let newState {
                setState(idx, newState)
                if newState == .running || newState == .waiting {
                    unarchiveOnResume(key)
                }
            }
            sessions[idx].lastEventTs = now
            sessions[idx].lastActivity = now
            sessions[idx].lastEvent = event.event
            if RenameCache.get(key) == nil, let title = event.title, !title.isEmpty {
                sessions[idx].title = title
            }
            if let cwd = event.cwd { sessions[idx].cwd = cwd }
        } else {
            sessions.append(AgentSession(
                key: key,
                agent: event.agent,
                project: event.project ?? event.cwd ?? "?",
                title: event.title ?? event.sessionId.prefix(8).description,
                state: newState ?? .waiting,
                lastActivity: now,
                lastEvent: event.event,
                lastEventTs: now,
                cwd: event.cwd
            ))
        }
        publishSoon()
    }

    /// Transcript-derived upsert. Event-driven state wins while fresh (<60s);
    /// otherwise state is derived from transcript mtime freshness.
    /// Staleness alone never means "done": a long build or a silently working
    /// agent writes nothing to its transcript for minutes. fresh → running;
    /// stale → idle (gray) — the only roads to done are explicit events
    /// (stop/session-end), a MERGED PR, a dead tmux mirror, or — for pi — the
    /// deck extension's status.json (working/waiting/closed is exact ground
    /// truth, so pi skips the transcript-freshness guessing entirely).
    func upsertTranscript(_ info: TranscriptInfo, path: String) {
        let key = "\(info.agent):\(info.sessionId)"
        let now = Date()
        let fresh = now.timeIntervalSince(info.lastActivity) < 120
        // New sessions from stale transcripts start as 確認待ち (the default
        // resting state), never done — idle only comes from the 2h decay rule.
        let derived: SessionState = liveState(info, now: now) ?? (fresh ? .running : .waiting)

        if let idx = sessions.firstIndex(where: { $0.key == key }) {
            var s = sessions[idx]
            s.lastActivity = info.lastActivity
            s.project = info.project
            s.transcriptPath = path
            s.branch = info.gitBranch ?? s.branch
            s.lastAssistant = info.lastAssistant ?? s.lastAssistant
            s.firstPrompt = info.firstPrompt ?? s.firstPrompt
            s.startedAt = info.startedAt ?? s.startedAt
            s.hasWorktree = s.hasWorktree || info.hasWorktree
            s.liveStatus = info.liveStatus ?? s.liveStatus
            s.liveStatusAt = info.liveStatusAt ?? s.liveStatusAt
            s.parentID = info.parentID ?? s.parentID
            if let cwd = info.cwd { s.cwd = cwd }
            // FM backfill only for still-placeholder titles ("生成済みは変えない"):
            // sessions already carrying a real title (native ai-title, FM cache,
            // rename, or a first-prompt prefix) are never re-enqueued.
            let placeholderTitle = s.title.isEmpty || s.title == String(s.sessionId.prefix(8))
            if let manual = RenameCache.get(key) {
                s.title = manual
            } else if s.title.isEmpty || placeholderTitle || info.title != nil {
                if let t = info.title, !t.isEmpty {
                    s.title = t
                } else if let cached = TitleCache.get(key) {
                    s.title = cached
                } else if let p = info.firstPrompt, placeholderTitle {
                    s.title = String(p.prefix(60))
                }
            }
            let eventFresh = now.timeIntervalSince(s.lastEventTs) < 3600
            sessions[idx] = s
            if placeholderTitle, info.title == nil, TitleCache.get(key) == nil,
               let p = s.firstPrompt, !p.isEmpty {
                TitleBackfiller.shared.enqueue(key, p)
            }
            // Fresh transcript → running (revives an idle session the moment
            // the agent writes again; archived sessions that resumed are
            // pulled back to the board too). Stale + known tmux mirror: leave
            // the state alone — decayStaleSessions probes liveness as ground
            // truth instead of guessing from transcript silence. pi sessions
            // skip this guessing: status.json is exact.
            if !eventFresh {
                if let live = liveState(info, now: now) {
                    setState(idx, live)
                } else if fresh {
                    setState(idx, .running)
                    unarchiveOnResume(key)
                } else if s.state == .running && s.tmuxSession == nil {
                    // 基本状態は「確認待ち」。アイドルへは decay の
                    // 「2時間放置」ルールでのみ落ちる。
                    // decay が確定させた idle / done / 失敗 を waiting へ
                    // 巻き戻してはいけない。スキャンごとにアイドル↔入力待ち
                    // が取り合いになるのが「アイドル判定おかしい」の原因。
                    setState(idx, .waiting)
                }
            }
        } else {
            let title = RenameCache.get(key)
                ?? info.title
                ?? TitleCache.get(key)
                ?? (info.firstPrompt.map { String($0.prefix(60)) })
                ?? String(info.sessionId.prefix(8))
            sessions.append(AgentSession(
                key: key,
                agent: info.agent,
                project: info.project,
                title: title,
                state: derived,
                lastActivity: info.lastActivity,
                lastEvent: "transcript",
                // No real AgentEvent arrived: lastEventTs stays distantPast so
                // transcript/live-status freshness owns the state from the
                // first upsert instead of being frozen for an hour.
                lastEventTs: .distantPast,
                cwd: info.cwd,
                transcriptPath: path,
                branch: info.gitBranch,
                lastAssistant: info.lastAssistant,
                firstPrompt: info.firstPrompt,
                startedAt: info.startedAt,
                hasWorktree: info.hasWorktree,
                liveStatus: info.liveStatus,
                liveStatusAt: info.liveStatusAt,
                parentID: info.parentID
            ))
            if info.title == nil, TitleCache.get(key) == nil,
               let prompt = info.firstPrompt, !prompt.isEmpty {
                TitleBackfiller.shared.enqueue(key, prompt)
            }
        }
        // サブエージェントの活動で親も「生きている」扱いにする (親カードへ
        // 内包表示するため、親が古い位置に沈まないように lastActivity 更新)。
        if let pid = info.parentID {
            let parentKey = "\(info.agent):\(pid)"
            if let pidx = sessions.firstIndex(where: { $0.key == parentKey }),
               sessions[pidx].lastActivity < info.lastActivity {
                sessions[pidx].lastActivity = info.lastActivity
            }
        }
        publishSoon()
    }

    func setTitle(key: String, _ title: String) {
        guard let idx = sessions.firstIndex(where: { $0.key == key }) else { return }
        sessions[idx].title = title
        publishSoon()
    }

    /// Manual rename: wins over AI/transcript titles forever (persisted).
    func rename(key: String, _ title: String) {
        guard let idx = sessions.firstIndex(where: { $0.key == key }) else { return }
        sessions[idx].title = title
        RenameCache.set(key, title)
        publishSoon()
    }

    /// External ground truth from `gh` and the tmux/status probes: MERGED flips
    /// the session to done, a live tmux mirror enables real-time attach.
    func applyEnrichment(key: String, prState: String?, prNumber: Int? = nil, tmux: String? = nil, branch: String? = nil) {
        guard let idx = sessions.firstIndex(where: { $0.key == key }) else { return }
        if let tmux { sessions[idx].tmuxSession = tmux }
        if let branch, !branch.isEmpty { sessions[idx].branch = branch }
        if let prState {
            sessions[idx].prState = prState
            sessions[idx].prNumber = prNumber
            if prState == "MERGED" {
                setState(idx, .done)
                Notifier.shared.sessionEvent(.prMerged, session: sessions[idx])
            }
        }
        publishSoon()
    }

    private func setState(_ idx: Int, _ new: SessionState) {
        let old = sessions[idx].state
        guard old != new else { return }
        sessions[idx].state = new
        switch new {
        case .waiting:
            Notifier.shared.sessionEvent(.waiting, session: sessions[idx])
        case .done where old == .running || old == .waiting:
            Notifier.shared.sessionEvent(.done, session: sessions[idx])
            Digest.shared.distill(sessions[idx])
        case .failed:
            Notifier.shared.sessionEvent(.failed, session: sessions[idx])
        default:
            break
        }
    }

    /// Sessions whose transcript went stale used to flip running -> done —
    /// that marked long-running builds (no transcript writes for minutes)
    /// as 完了 and made the board flicker as state flapped done↔running.
    /// Now staleness only ever means idle; "done" needs a real signal:
    /// the tmux mirror (if any) dying is the only automatic one here, and
    /// explicit stop/session-end events and MERGED PRs are the others.
    func decayStaleSessions() {
        let now = Date()
        var changed = false
        for idx in sessions.indices {
            let s = sessions[idx]
            // pi sessions with a live status.json are governed by the deck
            // extension, not by transcript silence. Re-derive from the stored
            // status each poll so working/waiting degrades to idle once the
            // file ages past 2h — even when no new file event ever arrives
            // (e.g. the pi process died mid-turn without writing "closed").
            if s.agent == "pi", let st = s.liveStatus {
                let liveAt = s.liveStatusAt ?? .distantPast
                let stale = st != "closed" && now.timeIntervalSince(liveAt) > 2 * 3600
                let target: SessionState? = st == "closed" ? .done
                    : stale ? .idle
                    : st == "working" ? .running
                    : st == "waiting" ? .waiting : nil
                if let target, s.state != target {
                    setState(idx, target)
                    changed = true
                }
                continue
            }
            let eventFresh = now.timeIntervalSince(s.lastEventTs) < 3600
            // 10min of silence, not an hour: a finished session must stop
            // showing 実行中 long before the old 3600s window expired.
            let transcriptFresh = now.timeIntervalSince(s.lastActivity) < 600
            guard !eventFresh && !transcriptFresh else { continue }
            guard s.state == .running || s.state == .waiting else { continue }
            let before = s.state
            if s.state == .running {
                // 実行中の沈黙を「アイドル」にしない: ミラーが生きていれば
                // 黙々ビルド中のまま。死んでいれば実績として done。ミラー
                // が無い場合は基本状態の「確認待ち」へ落ちるだけで、
                // アイドル判定は下の 2 時間ルールが担当する。
                if let tmux = s.tmuxSession {
                    // Ground truth: the tmux mirror really ended → done.
                    // Still alive → the agent is mid-thought; keep the state.
                    if tmuxSessionAlive(tmux) { continue }
                    setState(idx, .done)
                } else {
                    // No mirror and no events: honest state is 確認待ち —
                    // never done (a dead checkmark is worse than a dot),
                    // and never idle yet.
                    setState(idx, .waiting)
                }
                changed = changed || before != sessions[idx].state
                continue
            }
            // waiting: 「デフォルトは確認待ち、2時間放置でアイドル」。
            if now.timeIntervalSince(s.lastActivity) < 2 * 3600 { continue }
            if let tmux = s.tmuxSession {
                if tmuxSessionAlive(tmux) { continue }
                setState(idx, .done)
            } else {
                setState(idx, .idle)
            }
            changed = changed || before != sessions[idx].state
        }
        // Nothing to decay → skip the pointless board re-render every poll.
        if changed { publishSoon() }
    }

    /// 完了・アイドルセッションが「自動アーカイブ」の猶予時間を過ぎたら
    /// サイドバーのアーカイブへ自動で移す (day-based cutoff を待たず、
    /// 今日の終了分もボードが雑多にならないようにする)。手動で戻した
    /// (manualRestored) セッションは対象外。
    func autoArchiveFinished() {
        let now = Date()
        let ui = UISettings.shared
        guard ui.autoArchiveEnabled else { return }
        let grace = now.addingTimeInterval(-ui.autoArchiveDoneHours * 3600)
        var archivedAny = false
        for s in sessions where (s.state == .done || s.state == .idle)
            && s.lastActivity < grace
            && !manuallyArchived.contains(s.key)
            && !manuallyRestored.contains(s.key) {
            manuallyArchived.insert(s.key)
            autoArchived.insert(s.key)
            archivedAny = true
        }
        if archivedAny {
            persistArchiveState()
            publishSoon()
        }
    }

    /// `tmux has-session` spawns a process; cache liveness per mirror for 15s
    /// so the 10s decay poll doesn't exec a binary over and over.
    private var tmuxAliveCache: [String: (alive: Bool, checked: Date)] = [:]

    private func tmuxSessionAlive(_ name: String) -> Bool {
        let now = Date()
        if let cached = tmuxAliveCache[name], now.timeIntervalSince(cached.checked) < 15 {
            return cached.alive
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["tmux", "has-session", "-t", "=" + name]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            let alive = p.terminationStatus == 0
            tmuxAliveCache[name] = (alive, now)
            return alive
        } catch {
            return false
        }
    }

    private func stateFor(event: String) -> SessionState? {
        switch event {
        case "session-start", "prompt-submit", "tool-use", "agent-turn": .running
        case "notification", "permission-request": .waiting
        case "stop", "session-end": .done
        case "error", "failure": .failed
        default: nil
        }
    }

    /// pi deck status.json → board state. Exact while fresh; a working/waiting
    /// status whose file went stale (2h, matching the deck extension's own
    /// STALE_MS) degrades to idle instead of lying "実行中". closed → done.
    private func liveState(_ info: TranscriptInfo, now: Date) -> SessionState? {
        guard info.agent == "pi", let status = info.liveStatus else { return nil }
        let stale = status != "closed" && now.timeIntervalSince(info.liveStatusAt ?? .distantPast) > 2 * 3600
        switch status {
        case "closed": return .done
        case "working": return stale ? .idle : .running
        case "waiting": return stale ? .idle : .waiting
        default: return nil
        }
    }
}
