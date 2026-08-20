import Foundation
import Network

/// MCP (Model Context Protocol) server, Streamable HTTP transport, on
/// 127.0.0.1:47837 — zero dependencies (Network.framework), so Cursor,
/// Claude Desktop, opencode and any other MCP client can connect to the
/// live AgentDeck state.
///
/// Endpoints:
///   GET    /mcp           -> SSE stream (server -> client notifications)
///   POST   /mcp           -> JSON-RPC 2.0 (initialize / tools/list / tools/call …)
///   OPTIONS /mcp          -> CORS preflight
///   GET    /mcp/health    -> {"ok":true,"sessions":N,"tools":7}
///
/// Tools expose the "物忘れ防止・リマインド" surface:
///   status / list_sessions / session_summary / resume_session /
///   stale_sessions / vault_today / vault_read
///
/// The server is stateless (no mcp-session-id required). Every RPC hops to
/// the main actor once, because SessionStore is @MainActor; the socket
/// never blocks.
final class MCPServer: @unchecked Sendable {
    static let port: UInt16 = 47837
    static let serverName = "agentdeck-mcp"
    static let serverVersion = "1.0.0"
    static let protocolVersion = "2025-03-26"

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "agentdeck.mcp")
    /// Live SSE clients — kept alive with comment frames so idle connections
    /// don't get cut by NAT/firewall timeouts.
    private var sseClients: [NWConnection] = []

    func start() {
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.stateUpdateHandler = { state in
                if case let .failed(error) = state {
                    NSLog("AgentDeck MCPServer failed: \(error)")
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
            NSLog("AgentDeck MCPServer listening on 127.0.0.1:\(Self.port)")
        } catch {
            NSLog("AgentDeck MCPServer start error: \(error)")
            MainActor.assumeIsolated {
                ErrorCenter.shared.post("MCP Server の起動に失敗しました", detail: "\(error)")
            }
        }
    }

    // MARK: - connection plumbing

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
            var buf = buffer
            if let data { buf.append(data) }
            if error != nil {
                connection.cancel()
                self.sseClients.removeAll { $0 === connection }
                return
            }
            if let request = ParsedRequest(from: buf) {
                self.route(request, on: connection)
            } else {
                self.receive(connection, buffer: buf)
            }
        }
    }

    /// Routes one parsed HTTP request; the socket queue never blocks on the
    /// main actor (same pattern as EventServer).
    private func route(_ request: ParsedRequest, on connection: NWConnection) {
        switch (request.method, request.path) {
        case ("OPTIONS", _):
            respond(connection, status: "204 No Content", contentType: nil, body: "")
        case ("GET", "/mcp"):
            openSSE(connection)
        case ("GET", "/mcp/health"):
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let store = SessionStore.shared
                    let body = "{\"ok\":true,\"sessions\":\(store.sessions.count),\"events\":\(store.eventCount),\"tools\":\(Self.tools.count)}"
                    self.respond(connection, status: "200 OK", contentType: "application/json", body: body)
                }
            }
        case ("POST", "/mcp"):
            handleRPC(request, on: connection)
        default:
            respond(connection, status: "404 Not Found", contentType: "application/json",
                    body: "{\"ok\":false}")
        }
    }

    private func respond(_ connection: NWConnection, status: String, contentType: String?, body: String) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Access-Control-Allow-Headers: content-type, mcp-session-id, authorization\r\n"
        head += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        if let contentType {
            head += "Content-Type: \(contentType)\r\n"
            head += "Content-Length: \(body.utf8.count)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(Data(body.utf8))
        connection.send(content: out, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - SSE (Streamable HTTP server -> client channel)

    private func openSSE(_ connection: NWConnection) {
        sseClients.append(connection)
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: text/event-stream\r
        Cache-Control: no-cache\r
        Access-Control-Allow-Origin: *\r
        Connection: keep-alive\r
        \r

        """
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] _ in
            self?.keepAlive(connection)
        })
        // Detect client disconnect so the keep-alive chain stops.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] _, _, _, error in
            if error != nil {
                connection.cancel()
                self?.sseClients.removeAll { $0 === connection }
            }
        }
    }

    /// Comment frames every 25s: valid SSE, ignored by MCP clients, keeps
    /// NAT mappings alive. Cancels itself once the peer is gone.
    private func keepAlive(_ connection: NWConnection) {
        queue.asyncAfter(deadline: .now() + 25) { [weak self, weak connection] in
            guard let self, let connection, self.sseClients.contains(where: { $0 === connection }) else { return }
            connection.send(content: Data(": keep-alive\n\n".utf8), completion: .contentProcessed { _ in
                self.keepAlive(connection)
            })
        }
    }

    // MARK: - JSON-RPC

    private func handleRPC(_ request: ParsedRequest, on connection: NWConnection) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.routeRPC(request, on: connection)
            }
        }
    }

    @MainActor
    private func routeRPC(_ request: ParsedRequest, on connection: NWConnection) {
        let store = SessionStore.shared
        guard let obj = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let method = obj["method"] as? String
        else {
            let e = rpcError(id: nil, code: -32700, message: "Parse error: invalid JSON-RPC")
            respond(connection, status: "400 Bad Request", contentType: "application/json", body: e)
            return
        }
        let id = obj["id"]
        let params = obj["params"] as? [String: Any]

        // Notifications never get a response — 202 Accepted, empty body.
        if method.hasPrefix("notifications/") {
            let head = "HTTP/1.1 202 Accepted\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        switch method {
        case "initialize":
            let result: [String: Any] = [
                "protocolVersion": Self.protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": Self.serverName, "version": Self.serverVersion],
            ]
            respond(connection, status: "200 OK", contentType: "application/json", body: rpcResult(id: id, result))
        case "ping":
            respond(connection, status: "200 OK", contentType: "application/json", body: rpcResult(id: id, [:]))
        case "tools/list":
            let result: [String: Any] = ["tools": Self.tools]
            respond(connection, status: "200 OK", contentType: "application/json", body: rpcResult(id: id, result))
        case "tools/call":
            let (isError, payload) = callTool(store, name: params?["name"] as? String ?? "", arguments: params?["arguments"] as? [String: Any] ?? [:])
            let result: [String: Any] = [
                "content": [["type": "text", "text": payload]],
                "isError": isError,
            ]
            respond(connection, status: "200 OK", contentType: "application/json", body: rpcResult(id: id, result))
        case "resources/list":
            // Read-only host app: no resources registered yet.
            respond(connection, status: "200 OK", contentType: "application/json",
                    body: rpcResult(id: id, ["resources": []]))
        default:
            let e = rpcError(id: id, code: -32601, message: "Method not found: \(method)")
            respond(connection, status: "200 OK", contentType: "application/json", body: e)
        }
    }

    private func rpcResult(id: Any?, _ result: [String: Any]) -> String {
        var out: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { out["id"] = id }
        return json(out)
    }

    private func rpcError(id: Any?, code: Int, message: String) -> String {
        var out: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]
        if let id { out["id"] = id }
        return json(out)
    }

    private func json(_ obj: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    // MARK: - tools

    nonisolated(unsafe) private static let tools: [[String: Any]] = [
        [
            "name": "status",
            "description": "AgentDeck の全体ステータス (状態別セッション数・最新アクティビティ)。作業開始前の最初の一発に最適。",
            "inputSchema": ["type": "object", "properties": [:]] as [String: Any],
        ],
        [
            "name": "list_sessions",
            "description": "全エージェントセッション一覧 (pi/deepseek/opencode2/claude-code/codex/qwen)。状態・最終活動・プロジェクト・セッションID・再開コマンドを返す。物忘れ防止のため作業開始前/再開前に呼ぶこと。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "state": ["type": "string", "enum": ["running", "waiting", "done", "failed", "idle"], "description": "状態で絞り込み (省略時: 全部)"],
                    "project": ["type": "string", "description": "プロジェクト名で部分一致絞り込み"],
                    "limit": ["type": "integer", "description": "最大件数 (既定 30)"],
                ],
            ] as [String: Any],
        ],
        [
            "name": "session_summary",
            "description": "セッションのタイトル・要約・最初の指示・最後の成果・蒸留ログ(vault)を返す。作業再開前に必ず呼び、文脈を取り戻すこと。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "sessionId": ["type": "string", "description": "セッションID (ses_… または agent:ses_… 形式)"],
                ],
                "required": ["sessionId"],
            ] as [String: Any],
        ],
        [
            "name": "resume_session",
            "description": "セッションの再開コマンド (例: opencode2 --session ses_…, pi --session <uuid>, claude --resume ses_…, deepseek: open -a 'DeepSeek Harness') と作業ディレクトリを返す。新しいターミナル/エージェントで続きを再開するときに使う。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "sessionId": ["type": "string", "description": "セッションID (ses_… または agent:ses_… 形式)"],
                ],
                "required": ["sessionId"],
            ] as [String: Any],
        ],
        [
            "name": "stale_sessions",
            "description": "放置リマインダ。実行中/入力待ち/失敗のまま一定時間 (既定10分) 動いていないセッションを返す。終了し忘れや入力待ちの放置を防ぐ。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "minutes": ["type": "integer", "description": "放置判定の閾値(分) (既定 10)"],
                ],
            ] as [String: Any],
        ],
        [
            "name": "vault_today",
            "description": "今日の蒸留ログ (~/dev/agentdeck/vault/YYYY-MM-DD.md) の全文。今日完了した作業の要約。1日のはじめに読んで昨日の続きを思い出すのにも使う。",
            "inputSchema": ["type": "object", "properties": [:]] as [String: Any],
        ],
        [
            "name": "vault_read",
            "description": "指定日 (YYYY-MM-DD) の蒸留ログ全文を返す。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "date": ["type": "string", "description": "日付 YYYY-MM-DD"],
                ],
                "required": ["date"],
            ] as [String: Any],
        ],
    ]

    @MainActor
    private func callTool(_ store: SessionStore, name: String, arguments: [String: Any]) -> (Bool, String) {
        switch name {
        case "status": return (false, statusResult(store))
        case "list_sessions": return (false, listSessions(store, arguments))
        case "session_summary": return (false, sessionSummary(store, arguments))
        case "resume_session": return (false, resumeSession(store, arguments))
        case "stale_sessions": return (false, staleSessions(store, arguments))
        case "vault_today": return (false, vaultToday())
        case "vault_read": return (false, vaultRead(arguments))
        default:
            return (true, "{\"error\":\"unknown tool: \(name)\"}")
        }
    }

    // MARK: tool implementations

    @MainActor
    private func statusResult(_ store: SessionStore) -> String {
        var byState: [String: Int] = [:]
        for s in store.sessions { byState[s.state.rawValue, default: 0] += 1 }
        var out: [String: Any] = [
            "app": "AgentDeck",
            "mcp": "\(Self.serverName) v\(Self.serverVersion)",
            "protocolVersion": Self.protocolVersion,
            "sessions": store.sessions.count,
            "events": store.eventCount,
            "byState": byState,
        ]
        if let newest = store.sessions.max(by: { $0.lastActivity < $1.lastActivity }) {
            out["newestActivity"] = iso(newest.lastActivity)
            out["newestSession"] = newest.title
            out["newestState"] = newest.state.rawValue
        }
        return json(out)
    }

    @MainActor
    private func listSessions(_ store: SessionStore, _ args: [String: Any]) -> String {
        let limit = (args["limit"] as? Int) ?? 30
        var rows = store.sessions.sorted { $0.lastActivity > $1.lastActivity }
        if let state = (args["state"] as? String)?.lowercased() {
            rows = rows.filter { $0.state.rawValue == state }
        }
        if let project = args["project"] as? String, !project.isEmpty {
            rows = rows.filter { $0.project.localizedCaseInsensitiveContains(project) }
        }
        let out = rows.prefix(limit).map { sessionRow($0, idleFor: nil) }
        return json(["sessions": out])
    }

    @MainActor
    private func sessionSummary(_ store: SessionStore, _ args: [String: Any]) -> String {
        let query = args["sessionId"] as? String ?? ""
        guard !query.isEmpty else { return "{\"error\":\"sessionId required\"}" }
        if let s = findSession(store, query) {
            return json(summaryPayload(s, cachedSummary: SummaryCache.get(s.key, mtime: s.lastActivity)))
        }
        // Fallback: sessions outside the 7-day scan window live in the DB and
        // the vault — exactly the ones 物忘れ防止 exists for.
        if let row = OpenCodeDB.session(id: query) {
            let turns = OpenCodeDB.turns(sessionId: query, limit: 60)
            var s = AgentSession(
                key: "opencode2:\(query)",
                agent: "opencode2",
                project: row.directory,
                title: row.title ?? String(query.prefix(8)),
                state: .done,
                lastActivity: row.timeUpdated,
                lastEvent: "archive",
                cwd: row.directory,
                branch: row.branch,
                lastAssistant: turns.last(where: { $0.role == "assistant" })?.text,
                firstPrompt: turns.first(where: { $0.role == "user" })?.text
            )
            s.startedAt = row.timeCreated
            return json(summaryPayload(s, cachedSummary: nil))
        }
        // Last resort: the daily distill vault — opencode prunes its DB, the
        // vault never forgets.
        if let hit = vaultHit(for: query) {
            var out = vaultPayload(hit, sessionId: query)
            out["note"] = "SessionStore/DB の保持期間外。vault 蒸留ログより復元 (詳細度は蒸留時点のもの)"
            return json(out)
        }
        return "{\"error\":\"session not found: \(query)\"}"
    }

    private func vaultPayload(_ hit: VaultHit, sessionId: String) -> [String: Any] {
        var out: [String: Any] = [
            "sessionId": sessionId,
            "source": "vault",
            "vaultDistill": hit.body,
        ]
        if let title = hit.title { out["title"] = title }
        return out
    }

    private func summaryPayload(_ s: AgentSession, cachedSummary: String?) -> [String: Any] {
        var out: [String: Any] = [
            "sessionId": s.sessionId,
            "key": s.key,
            "agent": s.agent,
            "project": s.project,
            "title": s.title,
            "state": s.state.rawValue,
            "lastActivity": iso(s.lastActivity),
            "branch": s.branch ?? "",
            "pr": s.prNumber.map { "#\($0) \(s.prState ?? "")" } ?? s.prState ?? "",
            "firstPrompt": s.firstPrompt ?? "",
            "lastAssistant": String((s.lastAssistant ?? "").prefix(4000)),
            "resumeCommand": resumeCommand(s),
        ]
        if let cachedSummary, !cachedSummary.isEmpty {
            out["summary"] = cachedSummary
        }
        if let vault = vaultEntry(for: s.sessionId) {
            out["vaultDistill"] = vault
        }
        return out
    }

    @MainActor
    private func resumeSession(_ store: SessionStore, _ args: [String: Any]) -> String {
        let query = args["sessionId"] as? String ?? ""
        guard !query.isEmpty else { return "{\"error\":\"sessionId required\"}" }
        if let s = findSession(store, query) {
            return json([
                "sessionId": s.sessionId,
                "agent": s.agent,
                "title": s.title,
                "project": s.project,
                "cwd": s.cwd ?? "",
                "command": resumeCommand(s),
                "note": "cwd で実行すること",
            ])
        }
        guard let row = OpenCodeDB.session(id: query) else {
            if let hit = vaultHit(for: query) {
                var out = vaultPayload(hit, sessionId: query)
                out["resumable"] = false
                out["note"] = "このセッションは opencode の保持期間外 (DB から消去済み) で --session 再開は不可。vault 蒸留から文脈を復元してください。"
                return json(out)
            }
            return "{\"error\":\"session not found: \(query)\"}"
        }
        let s = AgentSession(
            key: "opencode2:\(query)",
            agent: "opencode2",
            project: row.directory,
            title: row.title ?? String(query.prefix(8)),
            state: .done,
            lastActivity: row.timeUpdated,
            lastEvent: "archive",
            cwd: row.directory,
            branch: row.branch
        )
        return json([
            "sessionId": s.sessionId,
            "agent": s.agent,
            "title": s.title,
            "project": s.project,
            "cwd": s.cwd ?? "",
            "command": resumeCommand(s),
            "note": "cwd で実行すること",
        ])
    }

    @MainActor
    private func staleSessions(_ store: SessionStore, _ args: [String: Any]) -> String {
        let minutes = max(1, (args["minutes"] as? Int) ?? 10)
        let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
        let rows = store.sessions
            .filter { ["running", "waiting", "failed"].contains($0.state.rawValue) && $0.lastActivity < cutoff }
            .sorted { $0.lastActivity < $1.lastActivity }
            .map { sessionRow($0, idleFor: minutes) }
        let total = store.sessions.filter { ["running", "waiting", "failed"].contains($0.state.rawValue) }.count
        return json(["stale": rows, "thresholdMinutes": minutes, "activeCount": total])
    }

    private func vaultToday() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let content = vaultFile(df.string(from: Date()))
        return json(["date": df.string(from: Date()), "content": content])
    }

    private func vaultRead(_ args: [String: Any]) -> String {
        let date = (args["date"] as? String) ?? ""
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        guard date.count == 10, df.date(from: date) != nil else {
            return "{\"error\":\"date must be YYYY-MM-DD\"}"
        }
        return json(["date": date, "content": vaultFile(date)])
    }

    // MARK: helpers

    @MainActor
    private func findSession(_ store: SessionStore, _ query: String?) -> AgentSession? {
        guard let query, !query.isEmpty else { return nil }
        return store.sessions.first { session in
            session.key == query || session.sessionId == query
        }
    }

    private func sessionRow(_ s: AgentSession, idleFor: Int?) -> [String: Any] {
        var row: [String: Any] = [
            "key": s.key,
            "sessionId": s.sessionId,
            "shortId": s.shortID,
            "agent": s.agent,
            "project": s.project,
            "title": s.title,
            "state": s.state.rawValue,
            "lastActivity": iso(s.lastActivity),
            "minutesAgo": Int(Date().timeIntervalSince(s.lastActivity) / 60),
            "branch": s.branch ?? "",
            "cwd": s.cwd ?? "",
            "resumeCommand": resumeCommand(s),
        ]
        if let pr = s.prNumber {
            row["pr"] = "#\(pr) \(s.prState ?? "")"
        }
        if let idleFor {
            row["idleMinutes"] = Int(Date().timeIntervalSince(s.lastActivity) / 60)
            row["reminder"] = "\(s.title) が \(idleFor) 分以上放置されています"
        }
        return row
    }

    /// Mirrors TerminalSheetView.command's resume mapping so the MCP answer
    /// and the app's terminal button never disagree.
    private func resumeCommand(_ s: AgentSession) -> String {
        let id = s.sessionId
        switch s.agent {
        case "claude-code": return "claude --resume \(id)"
        case "codex": return "codex resume \(id)"
        case "opencode2": return "opencode2 --session \(id)"
        case "pi": return "pi --session \(id)"
        case "deepseek": return "open -a 'DeepSeek Harness'"
        default: return "pi --session \(id)"
        }
    }

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private var vaultDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("dev/agentdeck/vault")
    }

    private func vaultFile(_ day: String) -> String {
        let path = vaultDir.appendingPathComponent("\(day).md").path
        guard FileManager.default.fileExists(atPath: path),
              let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "蒸留ログがありません: \(day).md"
        }
        return text
    }

    /// The vault section distilled from this session — grep the daily files
    /// for `session: \`<id>\`` and return the enclosing "## " section.
    private func vaultEntry(for sessionId: String) -> String? {
        vaultHit(for: sessionId)?.body
    }

    private struct VaultHit {
        let title: String?
        let body: String
    }

    private func vaultHit(for sessionId: String) -> VaultHit? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: vaultDir, includingPropertiesForKeys: nil) else { return nil }
        for file in files where file.pathExtension == "md" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: "\n")
            guard let idx = lines.firstIndex(where: { $0.contains("session: `\(sessionId)`") }) else { continue }
            var title: String?
            var section: [String] = []
            if idx > 0, lines[idx - 1].hasPrefix("## ") {
                title = String(lines[idx - 1].dropFirst(3))
            }
            for line in lines[idx...] {
                if line.hasPrefix("---") { break }
                section.append(line)
            }
            let out = section.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !out.isEmpty { return VaultHit(title: title, body: out) }
        }
        return nil
    }
}

private struct ParsedRequest {
    let method: String
    let path: String
    let body: Data

    init?(from data: Data) {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let header = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        method = String(parts[0])
        path = String(parts[1])

        var contentLength = 0
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 && kv[0].lowercased() == "content-length" {
                contentLength = Int(kv[1]) ?? 0
            }
        }
        let bodyStart = headerEnd.upperBound
        let available = data.count - data.distance(from: data.startIndex, to: bodyStart)
        guard available >= contentLength else { return nil }
        body = data[bodyStart..<data.index(bodyStart, offsetBy: contentLength)]
    }
}
