import Foundation

struct Turn: Identifiable, Sendable {
    let id = UUID()
    let role: String
    let text: String
    let ts: String?
}

/// Reads a session transcript into renderable turns (CLI JSONL + opencode2 DB).
enum TranscriptReader {
    private static let openCodePrefix = "opencode2://"
    /// Artifacts touched by this session — HTML reports plus local images and
    /// PDFs (write_file/artifact/record/file:// mentions).
    /// Schema-agnostic: regex over raw lines, deduped, existing files only.
    static func artifactPaths(path: String) -> [String] {
        if path.hasPrefix(openCodePrefix) {
            return OpenCodeDB.artifactPaths(sessionId: String(path.dropFirst(openCodePrefix.count)))
        }
        let isDeepSeek = path.contains("/.dsh/sessions/")
        guard let text = isDeepSeek
            ? Zstd.decompressText(path)
            : (try? String(contentsOfFile: path, encoding: .utf8)) else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        let pattern = try? NSRegularExpression(
            pattern: "(/[A-Za-z0-9_./@\\-]+\\.(?:html|png|jpe?g|gif|webp|heic|pdf))", options: .caseInsensitive)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = String(line)
            let ns = s as NSString
            for m in pattern?.matches(in: s, range: NSRange(location: 0, length: ns.length)) ?? [] {
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

    static func turns(path: String, limit: Int = 60) -> [Turn] {
        if path.hasPrefix(openCodePrefix) {
            return OpenCodeDB.turns(sessionId: String(path.dropFirst(openCodePrefix.count)), limit: limit)
        }
        let isDeepSeek = path.contains("/.dsh/sessions/")
        let text: String
        if isDeepSeek {
            // DeepSeek Harness stores the session zstd-compressed; decode the
            // whole file and window it the same way the raw JSONLs are.
            guard let full = Zstd.decompressText(path) else { return [] }
            text = String(full.suffix(1_500_000))
        } else {
            guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
            defer { try? handle.close() }
            let size = handle.seekToEndOfFile()
            let window: UInt64 = min(size, 1_500_000)
            handle.seek(toFileOffset: size - window)
            guard let t = String(data: handle.readDataToEndOfFile(), encoding: .utf8) else { return [] }
            text = t
        }

        var out: [Turn] = []
        let isCodex = path.contains("/.codex/sessions/")
        let isPi = path.contains("/.pi/agent/sessions/")
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if isDeepSeek {
                // {"type":"user/message"|"assistant/message","time":ms,"data":{…}}
                guard obj["type"] as? String == "user/message" || obj["type"] as? String == "assistant/message",
                      let d = obj["data"] as? [String: Any] else { continue }
                if obj["type"] as? String == "user/message" {
                    // Real user turns only — plugin/skill-catalog/agent-instructions
                    // lines carry other source kinds and are not conversation.
                    guard let src = d["source"] as? [String: Any],
                          (src["kind"] as? String) == "user" else { continue }
                    let t = dshText(d["content"])
                    guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                    out.append(Turn(role: "user", text: t, ts: dshTS(obj["time"])))
                } else {
                    guard let m = d["message"] as? [String: Any],
                          (m["role"] as? String) == "assistant" else { continue }
                    let t = dshText(m["content"])
                    guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                    out.append(Turn(role: "assistant", text: t, ts: dshTS(obj["time"])))
                }
                continue
            }
            if isPi {
                // pi: {"type":"message","message":{"role":"user|assistant",…}}
                guard obj["type"] as? String == "message",
                      let msg = obj["message"] as? [String: Any],
                      let role = msg["role"] as? String,
                      role == "user" || role == "assistant" else { continue }
                let t = piText(msg)
                guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                out.append(Turn(role: role == "user" ? "user" : "assistant", text: t, ts: obj["timestamp"] as? String))
                continue
            }
            if isCodex {
                guard obj["type"] as? String == "response_item",
                      let payload = obj["payload"] as? [String: Any],
                      payload["type"] as? String == "message" else { continue }
                let role = payload["role"] as? String ?? ""
                guard role == "user" || role == "assistant" else { continue }
                let t = (payload["content"] as? [[String: Any]] ?? [])
                    .compactMap { item -> String? in
                        let k = item["type"] as? String ?? ""
                        guard k == "input_text" || k == "output_text" || k == "text" else { return nil }
                        return item["text"] as? String
                    }
                    .joined(separator: "\n")
                if role == "user" && t.hasPrefix("<environment_context>") { continue }
                guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                out.append(Turn(role: role == "user" ? "user" : "assistant", text: t, ts: obj["timestamp"] as? String))
                continue
            }
            let type = obj["type"] as? String ?? ""
            guard type == "user" || type == "assistant" else { continue }
            if type == "user", let prov = obj["provenance"] as? String, prov != "real_user" { continue }
            guard let msg = obj["message"] as? [String: Any] else { continue }

            var text_: String?
            if let parts = msg["parts"] as? [[String: Any]], let t = parts.first?["text"] as? String {
                text_ = t
            } else if let s = msg["content"] as? String {
                text_ = s
            } else if let arr = msg["content"] as? [[String: Any]] {
                let joined = arr.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: "\n")
                if !joined.isEmpty { text_ = joined }
            }
            guard let t = text_, !t.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            out.append(Turn(role: type == "user" ? "user" : "assistant", text: t, ts: obj["timestamp"] as? String))
        }
        return Array(out.suffix(limit))
    }

    /// pi message content: a plain string or an array of typed blocks.
    private static func piText(_ msg: [String: Any]) -> String {
        if let s = msg["content"] as? String { return s }
        guard let arr = msg["content"] as? [[String: Any]] else { return "" }
        return arr.compactMap { item -> String? in
            guard (item["type"] as? String) == "text",
                  let t = item["text"] as? String else { return nil }
            return t
        }
        .joined(separator: "\n")
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
    }

    /// DeepSeek Harness timestamps are epoch milliseconds in the `time` field.
    private static func dshTS(_ time: Any?) -> String? {
        guard let ms = time as? NSNumber else { return nil }
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: ms.doubleValue / 1000))
    }
}
