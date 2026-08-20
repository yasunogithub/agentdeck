import Foundation
import SQLite3

/// Read-only access to the opencode2 (V2) SQLite store — the session list plus
/// user/assistant message JSON for titles, first prompts and turn history.
///
/// opencode writes its store to a versioned SQLite file in
/// ~/.local/share/opencode/ — the name varies by build: `opencode.db`
/// (unified V2 store), `opencode-next.db` (older V2), `opencode-ollama.db`
/// and `opencode-ollama-v2.db` (ollama-launched builds). All share the
/// `session_v2` / `session_message` tables (some older layouts use
/// `session` / `message`, workspace.branch). Every existing candidate is
/// scanned and merged (newest `time_updated` wins per session id), so the
/// live file is picked up no matter which name the CLI writes; the
/// table/column names are probed per connection.
///
/// Every call opens its own read-only connection (WAL-safe, never blocks the
/// writer), so a growing DB is picked up without locking or copying.
enum OpenCodeDB {
    /// The C header defines this macro; the Swift importer doesn't surface it.
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static let dbDir = FileManager.default.homeDirectoryForCurrentUser.path
        + "/.local/share/opencode/"

    static let dbCandidates = [
        "opencode.db",
        "opencode-next.db",
        "opencode-ollama-v2.db",
        "opencode-ollama.db",
    ]

    /// The candidate store with the newest mtime — used for change watching
    /// and availability; actual reads merge all candidates.
    static var dbPath: String {
        let fm = FileManager.default
        var best: (path: String, mtime: Date)? = nil
        for name in dbCandidates {
            let path = dbDir + name
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            if best == nil || mtime > best!.mtime { best = (path, mtime) }
        }
        return best?.path ?? dbDir + "opencode.db"
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: dbPath)
    }

    /// The legacy next.db keeps the old names: `session` (not `session_v2`)
    /// and `workspace.branch`. Probe both once per connection.
    private static func probe(_ db: OpaquePointer?) -> (session: String, hasBranch: Bool) {
        guard let db else { return ("session_v2", false) }
        var stmt: OpaquePointer?
        let ok = sqlite3_prepare_v2(db, "SELECT 1 FROM session_v2 LIMIT 1", -1, &stmt, nil)
        sqlite3_finalize(stmt)
        var stmt2: OpaquePointer?
        let bok = sqlite3_prepare_v2(db, "SELECT branch FROM workspace LIMIT 1", -1, &stmt2, nil)
        sqlite3_finalize(stmt2)
        return (ok == SQLITE_OK ? "session_v2" : "session", bok == SQLITE_OK)
    }

    struct SessionRow {
        let id: String
        let title: String?
        let directory: String
        let branch: String?
        let timeCreated: Date
        let timeUpdated: Date
        /// SubAgent セッションの親 (opencode V2 の session_v2.parent_id)。
        /// ボード上では親カードに内包して折りたたみ表示する。
        let parentID: String?
    }

    // MARK: sessions

    /// Scans all fresh sessions plus their first/last message texts across
    /// every candidate store, merging by session id (newest `time_updated`
    /// wins, non-nil title preferred on ties). `body` runs per session in one
    /// dispatch, newest activity first.
    ///
    /// `known` maps session id → last seen `time_updated`. Sessions whose
    /// `time_updated` hasn't advanced are skipped for the per-session message
    /// queries (2 prepared statements + JSON parses each) — they keep their
    /// first/last text in the board from the previous scan. This keeps the
    /// steady-state cost proportional to newly written sessions instead of
    /// the whole 7-day window on every DB write.
    ///
    /// `deepSince`: only sessions updated at/after this date get the
    /// first/last message queries. Older sessions (the board only shows the
    /// last 2 days) keep their DB title and skip the JSON parsing — this is
    /// what makes the startup scan cheap after a week of sessions.
    static func scan(since: Date, known: [String: Date] = [:], deepSince: Date? = nil, body: (SessionRow, String?, String?) -> Void) {
        struct Merged {
            var row: SessionRow
            var first: String?
            var last: String?
        }
        var merged: [String: Merged] = [:]
        for name in dbCandidates {
            let path = dbDir + name
            guard FileManager.default.fileExists(atPath: path) else { continue }
            scanFile(path: path, since: since, known: known, deepSince: deepSince) { row, first, last in
                if let existing = merged[row.id] {
                    if existing.row.timeUpdated > row.timeUpdated { return }
                    if existing.row.timeUpdated == row.timeUpdated,
                       existing.row.title != nil { return }
                }
                merged[row.id] = Merged(row: row, first: first, last: last)
            }
        }
        for m in merged.values.sorted(by: { $0.row.timeUpdated > $1.row.timeUpdated }) {
            body(m.row, m.first, m.last)
        }
    }

    private static func scanFile(path: String, since: Date, known: [String: Date], deepSince: Date?, body: (SessionRow, String?, String?) -> Void) {
        guard let db = open(path: path) else { return }
        defer { sqlite3_close(db) }
        let p = probe(db)
        let join = p.hasBranch ? "LEFT JOIN workspace w ON s.workspace_id = w.id" : ""
        let branchSel = p.hasBranch ? "w.branch" : "NULL"
        let sessionsSQL = """
            SELECT s.id, s.title, s.directory, \(branchSel), s.parent_id, s.time_created, s.time_updated
            FROM \(p.session) s \(join)
            WHERE s.time_archived IS NULL AND s.time_updated >= ?
            ORDER BY s.time_updated DESC LIMIT 200
            """
        var sStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sessionsSQL, -1, &sStmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(sStmt) }
        sqlite3_bind_int64(sStmt, 1, Int64((since.timeIntervalSince1970 * 1000).rounded()))

        var fStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            SELECT data FROM session_message
            WHERE session_id = ? AND type = 'user' ORDER BY seq ASC LIMIT 1
            """, -1, &fStmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(fStmt) }

        var lStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            SELECT data FROM session_message
            WHERE session_id = ? AND type = 'assistant' ORDER BY seq DESC LIMIT 50
            """, -1, &lStmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(lStmt) }

        while sqlite3_step(sStmt) == SQLITE_ROW {
            guard let id = col(sStmt, 0), !id.isEmpty else { continue }
            let row = SessionRow(
                id: id,
                title: col(sStmt, 1),
                directory: col(sStmt, 2) ?? "",
                branch: col(sStmt, 3),
                timeCreated: Date(timeIntervalSince1970: sqlite3_column_double(sStmt, 5) / 1000),
                timeUpdated: Date(timeIntervalSince1970: sqlite3_column_double(sStmt, 6) / 1000),
                parentID: col(sStmt, 4)
            )
            // Deep (first/last text) only for sessions that are new/updated
            // AND inside the display window — everything else is title-only.
            let needsDeep = row.timeUpdated >= (deepSince ?? .distantPast)
            if needsDeep, (known[id] == nil || known[id]! < row.timeUpdated) {
                let first = firstUserText(db: db, stmt: fStmt, sessionId: id)
                let last = lastAssistantText(db: db, stmt: lStmt, sessionId: id)
                body(row, first, last)
                continue
            }
            body(row, nil, nil)
        }
    }

    // MARK: single-session lookup (age-independent fallback for MCP)

    /// Direct row lookup by id across every candidate store — unlike `scan`
    /// there is no `since` cutoff, so old sessions (outside the 7-day scan
    /// window) are still reachable for summaries and resume commands.
    static func session(id: String) -> SessionRow? {
        for name in dbCandidates {
            let path = dbDir + name
            guard FileManager.default.fileExists(atPath: path),
                  let db = open(path: path) else { continue }
            defer { sqlite3_close(db) }
            let p = probe(db)
            let join = p.hasBranch ? "LEFT JOIN workspace w ON s.workspace_id = w.id" : ""
            let branchSel = p.hasBranch ? "w.branch" : "NULL"
            var stmt: OpaquePointer?
            let sql = """
                SELECT s.id, s.title, s.directory, \(branchSel), s.parent_id, s.time_created, s.time_updated
                FROM \(p.session) s \(join) WHERE s.id = ?
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                return SessionRow(
                    id: col(stmt, 0) ?? id,
                    title: col(stmt, 1),
                    directory: col(stmt, 2) ?? "",
                    branch: col(stmt, 3),
                    timeCreated: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5) / 1000),
                    timeUpdated: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6) / 1000),
                    parentID: col(stmt, 4)
                )
            }
        }
        return nil
    }

    // MARK: single-message lookups

    private static func firstUserText(db: OpaquePointer?, stmt: OpaquePointer?, sessionId: String) -> String? {
        guard let stmt else { return nil }
        sqlite3_reset(stmt)
        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let data = col(stmt, 0),
              let json = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any]
        else { return nil }
        let t = json["text"] as? String
        return (t?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? t : nil
    }

    private static func lastAssistantText(db: OpaquePointer?, stmt: OpaquePointer?, sessionId: String) -> String? {
        guard let stmt else { return nil }
        sqlite3_reset(stmt)
        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
        var seen = 0
        while sqlite3_step(stmt) == SQLITE_ROW, seen < 50 {
            seen += 1
            guard let data = col(stmt, 0),
                  let json = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any]
            else { continue }
            let text = assistantText(json)
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// "content": [{type: reasoning}, {type: text, text: ...}, {type: tool, ...}]
    private static func assistantText(_ json: [String: Any]) -> String {
        guard let content = json["content"] as? [[String: Any]] else { return "" }
        let parts = content.compactMap { item -> String? in
            guard item["type"] as? String == "text" else { return nil }
            return item["text"] as? String
        }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: turns for the detail view

    static func turns(sessionId: String, limit: Int = 60) -> [Turn] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            SELECT data, type FROM session_message
            WHERE session_id = ? ORDER BY seq ASC
            """, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)

        var out: [Turn] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let data = col(stmt, 0),
                  let type = col(stmt, 1),
                  type == "user" || type == "assistant",
                  let json = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any]
            else { continue }
            var text: String?
            if type == "user" {
                let t = json["text"] as? String
                text = (t?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? t : nil
            } else {
                let t = assistantText(json)
                text = t.isEmpty ? nil : t
            }
            guard let text else { continue }
            out.append(Turn(role: type == "user" ? "user" : "assistant", text: text, ts: createdTS(json)))
        }
        return Array(out.suffix(limit))
    }

    /// Artifacts referenced inside this session's message payloads
    /// (tool outputs carry the same /path/*.html|png|pdf mentions the JSONL does).
    static func artifactPaths(sessionId: String) -> [String] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            SELECT data FROM session_message WHERE session_id = ? ORDER BY seq ASC
            """, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)

        let pattern = try? NSRegularExpression(
            pattern: "(/[A-Za-z0-9_./@\\-]+\\.(?:html|png|jpe?g|gif|webp|heic|pdf))", options: .caseInsensitive)
        var seen = Set<String>()
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let data = col(stmt, 0) else { continue }
            let ns = data as NSString
            for m in pattern?.matches(in: data, range: NSRange(location: 0, length: ns.length)) ?? [] {
                var p = ns.substring(with: m.range)
                while let last = p.last, ",\"')]}:;".contains(last) { p.removeLast() }
                guard !seen.contains(p),
                      FileManager.default.fileExists(atPath: p) else { continue }
                seen.insert(p)
                out.append(p)
            }
        }
        return out
    }

    private static func createdTS(_ json: [String: Any]) -> String? {
        guard let time = json["time"] as? [String: Any],
              let ms = time["created"] as? NSNumber else { return nil }
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: ms.doubleValue / 1000))
    }

    // MARK: plumbing

    private static func open(path: String? = nil) -> OpaquePointer? {
        let file = path ?? dbPath
        guard FileManager.default.fileExists(atPath: file) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(file, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 1500)
        return db
    }

    private static func col(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: c)
    }
}
