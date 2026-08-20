import Foundation

struct TranscriptInfo {
    let agent: String
    let sessionId: String
    var project: String
    var title: String?
    var firstPrompt: String?
    var lastAssistant: String?
    var cwd: String?
    var gitBranch: String?
    var startedAt: Date?
    var hasWorktree = false
    var lastActivity: Date
    /// pi deck extension ground truth (~/.pi/agent/sessions/<cwd>/status.json):
    /// "working" | "waiting" | "closed" plus the time it was written. Only the
    /// newest session in a dir carries it (status.json belongs to the live one).
    var liveStatus: String?
    var liveStatusAt: Date?
    var liveTask: String?
    /// SubAgent セッションの親 (opencode2 の parent_id)。ボードでは親カードに
    /// 内包して既定で折りたたみ表示する。
    var parentID: String?
}

/// Derives sessions from CLI-native transcript files — the rot-proof data plane.
/// Sources:
///   ~/.claude/projects/<proj>/<session>.jsonl   (Claude Code; ai-title present)
///   ~/.qwen/projects/<proj>/chats/<session>.jsonl (Qwen Code; first real_user prompt)
///   ~/.pi/agent/sessions/<cwd-dir>/<ts>_<uuid>.jsonl (pi; header carries cwd)
///   ~/.local/share/opencode/opencode-next.db     (opencode2 V2 SQLite store)
///   ~/.dsh/sessions/<cwd-dir>/session-<uuid>/session.jsonl.zstd
///                                                (DeepSeek Harness; zstd JSONL)
final class TranscriptScanner: @unchecked Sendable {
    static let shared = TranscriptScanner()

    private let queue = DispatchQueue(label: "agentdeck.scanner")
    private var stream: FSEventStreamRef?
    private var known: [String: Date] = [:]
    /// mtime of opencode-next.db at the last scan (fallback trigger for -wal writes).
    private var lastOpenCodeScan: Date = .distantPast
    /// FSEvents on the opencode DB fire per -wal write (multiple times a second
    /// during an active session); each used to trigger a full-store rescans.
    /// Now the event only sets this flag and the 5s poll does the actual scan.
    private var openCodeDirty = false
    /// decayStaleSessions spawns `tmux has-session` probes; every 10s is plenty.
    private var lastDecay: Date = .distantPast
    private let maxAge: TimeInterval = 7 * 24 * 3600

    private var roots: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            home + "/.claude/projects",
            home + "/.qwen/projects",
            home + "/.codex/sessions",
            home + "/.pi/agent/sessions",
            home + "/.dsh/sessions",
            home + "/.local/share/opencode",
        ]
    }

    func start() {
        queue.async { self.startupScan() }
        startWatching()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.refreshStates() }
        }
    }

    func rescan() {
        queue.async { self.startupScan() }
    }

    // MARK: startup scan

    private func startupScan() {
        let fm = FileManager.default
        for root in roots {
            if root.hasSuffix("/.local/share/opencode") {
                scanOpenCodeDB()
                continue
            }
            guard let enumerator = fm.enumerator(atPath: root) else { continue }
            while let rel = enumerator.nextObject() as? String {
                guard rel.hasSuffix(".jsonl") || rel.hasSuffix(".jsonl.zstd") else { continue }
                // only top-level session files (skip subagent subdirs)
                let parts = rel.split(separator: "/")
                if root.hasSuffix(".codex/sessions") {
                    // yyyy/mm/dd/rollout-<ts>-<uuid>.jsonl — any depth, no subdirs
                } else if root.hasSuffix(".claude/projects") {
                    guard parts.count == 2 else { continue }
                } else if root.hasSuffix(".pi/agent/sessions") {
                    // <cwd-dir>/<ts>_<uuid>.jsonl — one flat dir per cwd
                    guard parts.count == 2 else { continue }
                } else if root.hasSuffix(".dsh/sessions") {
                    // <cwd-dir>/session-<uuid>/session.jsonl.zstd
                    guard parts.count == 3, rel.hasSuffix(".jsonl.zstd") else { continue }
                } else {
                    guard parts.count == 3, parts[1] == "chats" else { continue }
                }
                let path = root + "/" + rel
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date,
                      Date().timeIntervalSince(mtime) < maxAge else { continue }
                ingest(path: path, mtime: mtime)
            }
        }
        NSLog("AgentDeck startup scan done: \(known.count) sessions")
    }

    // MARK: FSEvents watch

    private func startWatching() {
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let paths = roots as CFArray
        var flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        flags |= FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (_, info, numEvents, eventPaths, _, _) in
                guard let info else { return }
                let scanner = Unmanaged<TranscriptScanner>.fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(eventPaths, to: CFArray.self)
                for i in 0..<numEvents {
                    let path = unsafeBitCast(CFArrayGetValueAtIndex(paths, i), to: CFString.self) as String
                    scanner.queue.async { scanner.onChanged(path: path) }
                }
            },
            &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
        NSLog("AgentDeck watching \(roots)")
    }

    private func onChanged(path: String) {
        let isOpenCodeDB = path.contains("/.local/share/opencode/")
            && (path.hasSuffix(".db") || path.hasSuffix(".db-wal") || path.hasSuffix(".db-shm"))
        let isPiStatus = path.contains("/.pi/agent/sessions/") && path.hasSuffix("status.json")
        guard path.hasSuffix(".jsonl") || path.hasSuffix(".jsonl.zstd") || isOpenCodeDB || isPiStatus else { return }
        let isClaude = path.contains("/.claude/projects/")
        let isQwen = path.contains("/.qwen/projects/") && path.contains("/chats/")
        let isCodex = path.contains("/.codex/sessions/")
        let isPi = path.contains("/.pi/agent/sessions/")
        let isDeepSeek = path.contains("/.dsh/sessions/")
        let isOpenCode = path.contains("/.local/share/opencode/")
        guard isClaude || isQwen || isCodex || isPi || isDeepSeek || isOpenCode else { return }
        if isOpenCode {
            openCodeDirty = true
            return
        }
        if isPiStatus {
            // The deck extension rewrites status.json on every agent start/end
            // and on quit. That's the state ground truth for the *live* session
            // in this dir — re-ingest the newest jsonl so working/waiting/closed
            // land on the board even when no transcript line was appended.
            reingestLatestPi(in: (path as NSString).deletingLastPathComponent)
            return
        }
        if isClaude {
            // .../projects/<proj>/<session>.jsonl
            let parts = path.split(separator: "/")
            guard parts.count >= 2, parts[parts.count - 1].hasSuffix(".jsonl") else { return }
        }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? Date()
        ingest(path: path, mtime: mtime)
    }

    // MARK: opencode2 SQLite store

    /// Full refresh of opencode2 sessions straight from the SQLite store.
    /// Cheap (one connection, a few prepared statements), so it runs on every
    /// DB write and on the 5s state poll.
    private func scanOpenCodeDB() {
        let now = Date()
        guard OpenCodeDB.isAvailable else { return }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: OpenCodeDB.dbPath),
           let mtime = attrs[.modificationDate] as? Date {
            lastOpenCodeScan = mtime
        }
        let cutoff = now.addingTimeInterval(-maxAge)
        let knownUpdated = known.reduce(into: [String: Date]()) { map, entry in
            guard entry.key.hasPrefix("opencode2://") else { return }
            map[String(entry.key.dropFirst("opencode2://".count))] = entry.value
        }
        OpenCodeDB.scan(since: cutoff, known: knownUpdated, deepSince: SessionStore.boardCutoff) { row, firstPrompt, lastAssistant in
            let path = "opencode2://\(row.id)"
            let isNew = known[path] == nil
            // time_updated が進んでいない行はボードに何も変えないので
            // 再 upsert しない。再 upsert のたびに全行の publish が走って
            // CPU を食うだけでなく、upsertTranscript の基本状態(確認待ち)
            // が decay のアイドル化と取り合って「アイドル判定おかしい」の
            // 一因にもなっていた。
            let advanced = known[path].map { $0 < row.timeUpdated } ?? false
            known[path] = row.timeUpdated
            guard isNew || advanced else { return }

            // Branch probe (git subprocess) stays out of the scanner queue:
            // Enricher resolves it asynchronously when the session is new.
            var info = TranscriptInfo(
                agent: "opencode2",
                sessionId: row.id,
                project: (row.directory as NSString).lastPathComponent,
                title: row.title,
                firstPrompt: firstPrompt,
                lastAssistant: lastAssistant,
                cwd: row.directory.isEmpty ? nil : row.directory,
                gitBranch: row.branch,
                startedAt: row.timeCreated,
                lastActivity: row.timeUpdated,
                parentID: row.parentID
            )
            if let cwd = info.cwd {
                info.project = (cwd as NSString).lastPathComponent
            }
            let captured = info
            if isNew && now.timeIntervalSince(row.timeUpdated) < 4 * 3600 {
                Enricher.shared.enrich(captured)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    SessionStore.shared.upsertTranscript(captured, path: path)
                }
            }
        }
    }

    // MARK: ingest

    private func ingest(path: String, mtime: Date) {
        let isClaude = path.contains("/.claude/projects/")
        let isCodex = path.contains("/.codex/sessions/")
        let isPi = path.contains("/.pi/agent/sessions/")
        let isDeepSeek = path.contains("/.dsh/sessions/")
        let agent = isClaude ? "claude-code"
            : isCodex ? "codex"
            : isPi ? "pi"
            : isDeepSeek ? "deepseek"
            : "pi"
        var sessionId = (path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
        if isCodex, let uuid = Self.codexSessionID(path: path) {
            sessionId = uuid
        }
        if isPi, let uuid = Self.piSessionID(path: path) {
            sessionId = uuid
        }
        if isDeepSeek, let dir = Self.dshSessionDir(path: path) {
            // …/session-<uuid>/session.jsonl.zstd — the dir is the canonical id
            // workspace.json and the projcache reference.
            sessionId = dir
        }
        let project = projectName(path: path, isClaude: isClaude)

        // DeepSeek Harness sessions are zstd-compressed; decode once here so
        // head/tail parsing never re-decompresses the same file per ingest.
        let zstdText = isDeepSeek ? Zstd.decompressText(path) : nil

        var info = TranscriptInfo(
            agent: agent, sessionId: sessionId, project: project,
            lastActivity: mtime
        )
        if !isClaude && !isDeepSeek {
            let wt = path.replacingOccurrences(of: ".jsonl", with: ".worktree.json")
            info.hasWorktree = FileManager.default.fileExists(atPath: wt)
        }

        let isNew = known[path] == nil
        known[path] = mtime
        if isNew || isCodex || isPi || isDeepSeek {
            // codex/pi/deepseek paths carry no project dir (pi/deepseek: only
            // the encoded cwd dir name), so the head must be re-parsed on
            // every ingest to keep cwd/branch/title stable across refreshes
            // and pick up late session_info/session/title entries.
            parseHead(path: path, zstd: zstdText, into: &info)
        }
        if info.agent == "pi", info.cwd != nil {
            // status.json (deck extension) is the state ground truth for the
            // newest session in this dir only — older sessions in the same
            // dir keep transcript-derived state.
            if Self.latestJsonl(in: (path as NSString).deletingLastPathComponent) == path,
               let st = Self.piStatus(dir: (path as NSString).deletingLastPathComponent) {
                info.liveStatus = st.status
                info.liveStatusAt = st.at
                info.liveTask = st.task
                // The status file refreshes during a long working turn while
                // the transcript is silent — that freshness is the activity
                // the board should sort and measure by.
                if let at = st.at, at > info.lastActivity {
                    info.lastActivity = at
                }
            }
        }
        parseTail(path: path, zstd: zstdText, into: &info)
        if let cwd = info.cwd {
            info.project = (cwd as NSString).lastPathComponent
        }
        let captured = info
        if isNew && Date().timeIntervalSince(mtime) < 4 * 3600 {
            Enricher.shared.enrich(captured)
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                SessionStore.shared.upsertTranscript(captured, path: path)
            }
        }
    }

    // MARK: pi live status

    private func reingestLatestPi(in dir: String) {
        guard let newest = Self.latestJsonl(in: dir),
              let attrs = try? FileManager.default.attributesOfItem(atPath: newest),
              let mtime = attrs[.modificationDate] as? Date else { return }
        ingest(path: newest, mtime: mtime)
    }

    /// The .jsonl with the newest mtime in a pi session dir — the session
    /// status.json describes.
    private static func latestJsonl(in dir: String) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        return entries
            .filter { $0.hasSuffix(".jsonl") }
            .map { dir + "/" + $0 }
            .max { a, b in
                (try? FileManager.default.attributesOfItem(atPath: a))?[.modificationDate] as? Date
                    ?? .distantPast <
                    ((try? FileManager.default.attributesOfItem(atPath: b))?[.modificationDate] as? Date ?? .distantPast)
            }
    }

    /// {status, updatedAt, task} from a pi session dir's status.json (written
    /// by the deck extension). Fails open: nil when absent/unreadable.
    private static func piStatus(dir: String) -> (status: String?, at: Date?, task: String?)? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: dir + "/status.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var at: Date?
        if let ms = obj["updatedAt"] as? NSNumber {
            at = Date(timeIntervalSince1970: ms.doubleValue / 1000)
        }
        return (obj["status"] as? String, at, obj["task"] as? String)
    }

    private func projectName(path: String, isClaude: Bool) -> String {
        let parts = path.split(separator: "/").map(String.init)
        // pi/deepseek: .../<sessions>/<cwd-dir>/… — decode the encoded cwd dir;
        // the header's cwd replaces this shortly after.
        if (path.contains("/.pi/agent/sessions/") || path.contains("/.dsh/sessions/")),
           let idx = parts.firstIndex(of: "sessions"), parts.count > idx + 1 {
            return Self.decodePiDir(parts[idx + 1])
        }
        // .../.claude/projects/<proj>/<file> or .../.qwen/projects/<proj>/chats/<file>
        if let idx = parts.firstIndex(of: "projects"), parts.count > idx + 1 {
            let encoded = parts[idx + 1]
            let decoded = encoded.replacingOccurrences(of: "-", with: "/")
            return (decoded as NSString).lastPathComponent
        }
        return "?"
    }

    /// pi encodes a cwd into a session dir as `--<path with / replaced by ->--`
    /// (e.g. /Users/…/agentdeck → --Users-…-dev-agentdeck--). Decoding is lossy
    /// when the real path contains hyphens, so the header's `cwd` is the source
    /// of truth — this is only a fallback project label.
    private static func decodePiDir(_ dir: String) -> String {
        var d = dir
        if d.hasPrefix("--") { d.removeFirst(2) }
        if d.hasSuffix("--") { d.removeLast(2) }
        return ((d.replacingOccurrences(of: "-", with: "/")) as NSString).lastPathComponent
    }

    private func refreshStates() {
        let now = Date()
        // opencode2 writes mostly to -wal; FSEvents (dirty flag) and DB mtime
        // advances both funnel into one scan per 5s poll, never per write.
        if OpenCodeDB.isAvailable {
            var shouldScan = openCodeDirty
            openCodeDirty = false
            if !shouldScan,
               let attrs = try? FileManager.default.attributesOfItem(atPath: OpenCodeDB.dbPath),
               let mtime = attrs[.modificationDate] as? Date,
               mtime > lastOpenCodeScan {
                shouldScan = true
            }
            if shouldScan {
                scanOpenCodeDB()
            }
        }
        guard now.timeIntervalSince(lastDecay) >= 10 else { return }
        lastDecay = now
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                SessionStore.shared.decayStaleSessions()
                SessionStore.shared.autoArchiveFinished()
            }
        }
    }

    // MARK: tail parsing (last AI output = where the session landed)

    private func parseTail(path: String, zstd: String? = nil, into info: inout TranscriptInfo) {
        guard let text = zstd.map({ String($0.suffix(131_072)) }) ?? Self.readFileTail(path) else { return }

        var last: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if info.agent == "deepseek" {
                guard obj["type"] as? String == "assistant/message",
                      let data = obj["data"] as? [String: Any],
                      let msg = data["message"] as? [String: Any],
                      (msg["role"] as? String) == "assistant" else { continue }
                let t = Self.dshText(msg["content"])
                if !t.isEmpty { last = t }
                continue
            }
            if info.agent == "codex" {
                guard obj["type"] as? String == "response_item",
                      let payload = obj["payload"] as? [String: Any],
                      payload["type"] as? String == "message",
                      (payload["role"] as? String) == "assistant" else { continue }
                let joined = (payload["content"] as? [[String: Any]] ?? [])
                    .compactMap { item -> String? in
                        let k = item["type"] as? String ?? ""
                        guard k == "output_text" || k == "text" else { return nil }
                        return item["text"] as? String
                    }
                    .joined(separator: " ")
                if !joined.trimmingCharacters(in: .whitespaces).isEmpty { last = joined }
                continue
            }
            if info.agent == "pi" {
                guard obj["type"] as? String == "message",
                      let msg = obj["message"] as? [String: Any],
                      (msg["role"] as? String) == "assistant" else { continue }
                let t = Self.piText(msg)
                if !t.isEmpty { last = t }
                continue
            }
            guard obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any] else { continue }
            var t: String?
            if let parts = msg["parts"] as? [[String: Any]], let s = parts.first?["text"] as? String {
                t = s
            } else if let s = msg["content"] as? String {
                t = s
            } else if let arr = msg["content"] as? [[String: Any]] {
                let joined = arr.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: " ")
                if !joined.isEmpty { t = joined }
            }
            if let t, !t.trimmingCharacters(in: .whitespaces).isEmpty { last = t }
        }
        info.lastAssistant = last
    }

    // MARK: head parsing

    private func parseHead(path: String, zstd: String? = nil, into info: inout TranscriptInfo) {
        guard let text = zstd.map({ String($0.prefix(65536)) }) ?? Self.readFileHead(path) else { return }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if info.startedAt == nil, let ts = obj["timestamp"] as? String {
                info.startedAt = Self.parseTS(ts)
            }

            if info.agent == "claude-code" {
                if info.title == nil, obj["type"] as? String == "ai-title", let t = obj["aiTitle"] as? String {
                    info.title = t
                }
                if info.gitBranch == nil, let br = obj["gitBranch"] as? String {
                    info.gitBranch = br
                }
                if info.firstPrompt == nil, obj["type"] as? String == "user",
                   let msg = obj["message"] as? [String: Any] {
                    info.firstPrompt = Self.claudeUserText(msg)
                    if info.cwd == nil, let cwd = obj["cwd"] as? String { info.cwd = cwd }
                }
            } else if info.agent == "codex" {
                let payload = obj["payload"] as? [String: Any]
                if obj["type"] as? String == "session_meta", let payload {
                    if info.cwd == nil, let cwd = payload["cwd"] as? String { info.cwd = cwd }
                    if info.gitBranch == nil, let git = payload["git"] as? [String: Any],
                       let br = git["branch"] as? String { info.gitBranch = br }
                } else if obj["type"] as? String == "response_item", let payload,
                          (payload["type"] as? String) == "message",
                          (payload["role"] as? String) == "user",
                          info.firstPrompt == nil,
                          let content = payload["content"] as? [[String: Any]] {
                    // codex stores no title; derive it from the first real
                    // user prompt (skipping the <environment_context> bootstrap)
                    for item in content where (item["type"] as? String) == "input_text" {
                        if let t = item["text"] as? String, !t.hasPrefix("<environment_context>") {
                            info.firstPrompt = t
                            info.title = String(t.prefix(60))
                            break
                        }
                    }
                }
            } else if info.agent == "pi" {
                switch obj["type"] as? String {
                case "session":
                    // header: {"type":"session","version":3,"id":uuid,"cwd":path}
                    if info.cwd == nil, let cwd = obj["cwd"] as? String, !cwd.isEmpty {
                        info.cwd = cwd
                    }
                case "session_info":
                    // /name set a display title: {"type":"session_info","name":…}
                    if info.title == nil, let name = obj["name"] as? String, !name.isEmpty {
                        info.title = name
                    }
                case "message":
                    guard info.firstPrompt == nil,
                          let msg = obj["message"] as? [String: Any],
                          (msg["role"] as? String) == "user" else { break }
                    let t = Self.piText(msg)
                    if !t.isEmpty { info.firstPrompt = t }
                default:
                    break
                }
            } else if info.agent == "deepseek" {
                // DeepSeek Harness: pi-like JSONL, zstd-compressed, epoch-ms
                // `time` fields. Real user turns have source.kind == "user"
                // (plugin/skill-catalog/agent-instructions lines are noise).
                switch obj["type"] as? String {
                case "session":
                    if info.startedAt == nil, let ms = obj["createdAt"] as? NSNumber {
                        info.startedAt = Date(timeIntervalSince1970: ms.doubleValue / 1000)
                    }
                    if info.cwd == nil, let cwd = obj["cwd"] as? String, !cwd.isEmpty {
                        info.cwd = cwd
                    }
                case "session/title":
                    if info.title == nil,
                       let data = obj["data"] as? [String: Any],
                       let name = data["title"] as? String, !name.isEmpty {
                        info.title = name
                    }
                case "user/message":
                    guard info.firstPrompt == nil,
                          let data = obj["data"] as? [String: Any],
                          let src = data["source"] as? [String: Any],
                          (src["kind"] as? String) == "user" else { break }
                    let t = Self.dshText(data["content"])
                    if !t.isEmpty { info.firstPrompt = t }
                default:
                    break
                }
            } else {
                if obj["type"] as? String == "user", obj["provenance"] as? String == "real_user",
                   info.firstPrompt == nil,
                   let msg = obj["message"] as? [String: Any],
                   let parts = msg["parts"] as? [[String: Any]],
                   let t = parts.first?["text"] as? String {
                    info.firstPrompt = t
                    if let cwd = obj["cwd"] as? String { info.cwd = cwd }
                    if let br = obj["gitBranch"] as? String { info.gitBranch = br }
                }
            }
            if info.title != nil && info.firstPrompt != nil { break }
        }
    }

    /// codex files are rollout-<ts>-<uuid>.jsonl under date dirs; the real id
    /// (what `codex resume <id>` takes) lives in the session_meta payload.
    static func codexSessionID(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let chunk = handle.readData(ofLength: 65536)
        guard let text = String(data: chunk, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "session_meta",
                  let payload = obj["payload"] as? [String: Any],
                  let id = payload["id"] as? String else { continue }
            return id
        }
        return nil
    }

    /// pi files are <timestamp>_<uuid>.jsonl; the uuid (what `pi --session`
    /// takes) is the part after the last underscore. Matches the header `id`.
    static func piSessionID(path: String) -> String? {
        let base = (path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
        guard let idx = base.lastIndex(of: "_") else { return nil }
        let uuid = String(base[base.index(after: idx)...])
        return uuid.isEmpty ? nil : uuid
    }

    /// DeepSeek Harness sessions live in …/session-<uuid>/session.jsonl.zstd;
    /// the session dir name is the id workspace.json and the projcache use.
    static func dshSessionDir(path: String) -> String? {
        let name = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return name.hasPrefix("session-") ? name : nil
    }

    /// deepseek message content: [{type: text|reasoning|tool-call, …}] — text blocks only.
    private static func dshText(_ content: Any?) -> String {
        guard let arr = content as? [[String: Any]] else { return "" }
        return arr.compactMap { item -> String? in
            guard (item["type"] as? String) == "text",
                  let t = item["text"] as? String else { return nil }
            return t
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// First 64KB of a raw (non-zstd) session file — the parseHead window.
    private static func readFileHead(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return String(data: handle.readData(ofLength: 65536), encoding: .utf8)
    }

    /// Last 128KB of a raw (non-zstd) session file — the parseTail window.
    private static func readFileTail(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        let tailSize: UInt64 = min(size, 131_072)
        handle.seek(toFileOffset: size - tailSize)
        return String(data: handle.readDataToEndOfFile(), encoding: .utf8)
    }

    nonisolated(unsafe) private static let tsFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parseTS(_ s: String) -> Date? {
        tsFormatter.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    private static func claudeUserText(_ msg: [String: Any]) -> String? {
        if let s = msg["content"] as? String { return s }
        if let arr = msg["content"] as? [[String: Any]] {
            for item in arr where item["type"] as? String == "text" {
                if let t = item["text"] as? String { return t }
            }
        }
        return nil
    }

    /// pi message content: a plain string or an array of
    /// {type: text|image|thinking|toolCall} blocks — text blocks only.
    private static func piText(_ msg: [String: Any]) -> String {
        if let s = msg["content"] as? String { return s }
        guard let arr = msg["content"] as? [[String: Any]] else { return "" }
        return arr.compactMap { item -> String? in
            guard (item["type"] as? String) == "text",
                  let t = item["text"] as? String else { return nil }
            return t
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// opencode2 doesn't record git branches yet; read the live one from the
/// session's directory instead (Enricher then resolves PR state via gh).
enum GitProbe {
    static func currentBranch(cwd: String) -> String? {
        guard let cwd = SafeCwd.resolve(cwd) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return nil
        }
        guard p.terminationStatus == 0 else { return nil }
        let s = String(data: (p.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty || s == "HEAD" ? nil : s
    }
}

/// zstd decompression for the DeepSeek Harness session store
/// (~/.dsh/sessions/<cwd>/session-<uuid>/session.jsonl.zstd). Apple's
/// Compression framework has no zstd, so this shells out to the `zstd` CLI
/// (Homebrew/ports) — same pattern as the git/tmux/gh probes elsewhere.
enum Zstd {
    static func decompressText(_ path: String) -> String? {
        guard let out = decode(path) else { return nil }
        return String(data: out, encoding: .utf8)
    }

    static func decode(_ path: String) -> Data? {
        let (exe, prefix) = command
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = prefix + ["-dc", path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            return nil
        }
        // Read the pipe to EOF *before* waiting, or a large decompressed
        // session (>64KB pipe buffer) deadlocks zstd on its stdout write.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return data
    }

    nonisolated(unsafe) private static var resolved: (String, [String])?
    private static var command: (String, [String]) {
        if let resolved { return resolved }
        let found: (String, [String])?
        if let bin = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/opt/local/bin/zstd"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            found = (bin, [])
        } else {
            found = nil
        }
        let value = found ?? ("/usr/bin/env", ["zstd"])
        resolved = value
        return value
    }
}
