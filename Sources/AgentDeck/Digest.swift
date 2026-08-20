import Foundation

/// On session completion, distills the transcript into the Markdown vault
/// (~/dev/agentdeck/vault/YYYY-MM-DD.md) via on-device FM. Plain Markdown =
/// grep-able, Obsidian-compatible, rebuildable — no proprietary store.
final class Digest: @unchecked Sendable {
    static let shared = Digest()

    private let lock = NSLock()
    private var inflight = Set<String>()

    func distill(_ session: AgentSession) {
        guard let path = session.transcriptPath else { return }
        lock.lock()
        guard !inflight.contains(session.key) else { lock.unlock(); return }
        inflight.insert(session.key)
        lock.unlock()

        Task.detached(priority: .utility) {
            let turns = TranscriptReader.turns(path: path, limit: 40)
            let compressed = turns.map {
                "\($0.role == "user" ? "ユーザー" : "AI"): \(String($0.text.prefix(200)))"
            }
            .joined(separator: "\n")
            let summary = await FMService.shared.summarize(transcript: compressed)

            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            let day = df.string(from: Date())
            let vaultDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("dev/agentdeck/vault")
            try? FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
            let file = vaultDir.appendingPathComponent("\(day).md")

            var md = ""
            if !FileManager.default.fileExists(atPath: file.path) {
                md += "# AgentDeck 蒸留ログ \(day)\n\n"
            }
            md += """
            ## \(session.title)
            - agent: \(session.agent) / session: `\(session.sessionId)` / project: \(session.project)
            - branch: \(session.branch ?? "-") / PR: \(session.prState ?? "-")

            \(summary)

            ---

            """
            if let handle = FileHandle(forWritingAtPath: file.path) {
                handle.seekToEndOfFile()
                handle.write(Data(md.utf8))
                try? handle.close()
            } else {
                try? md.write(to: file, atomically: true, encoding: .utf8)
            }
            NSLog("AgentDeck distilled \(session.key) -> \(file.path)")
        }
    }
}
