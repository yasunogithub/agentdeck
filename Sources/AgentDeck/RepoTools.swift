import AppKit
import Foundation

/// One-click repo tooling: open a session's folder in Finder, its PR/repo on
/// GitHub, and copy the handoff brief (引継書) to the clipboard.
enum RepoTools {
    /// git remote origin → https base URL.
    /// "git@github.com:org/repo.git" → "https://github.com/org/repo".
    static func remoteBase(cwd: String?) -> String? {
        guard let dir = SafeCwd.resolve(cwd) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", dir, "remote", "get-url", "origin"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return nil
        }
        guard p.terminationStatus == 0 else { return nil }
        let raw = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalize(raw)
    }

    static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("git@") {
            // git@github.com:org/repo.git → https://github.com/org/repo.git
            s = s.replacingOccurrences(of: "git@", with: "https://")
            if let colon = s.firstIndex(of: ":") {
                s.remove(at: colon)
                s.insert("/", at: colon)
            }
        } else if s.hasPrefix("ssh://git@") {
            s = s.replacingOccurrences(of: "ssh://git@", with: "https://")
        } else if s.hasPrefix("http://") {
            s = s.replacingOccurrences(of: "http://", with: "https://")
        }
        s = s.replacingOccurrences(of: ".git", with: "")
        guard s.hasPrefix("https://") else { return nil }
        return s
    }

    /// PR page when known, repo page otherwise.
    static func openPR(_ session: AgentSession) {
        guard let base = remoteBase(cwd: session.cwd) else { return }
        let url = session.prNumber.map { URL(string: "\(base)/pull/\($0)") ?? URL(string: base) } ?? URL(string: base)
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    static func openRepo(_ session: AgentSession) {
        guard let base = remoteBase(cwd: session.cwd), let url = URL(string: base) else { return }
        NSWorkspace.shared.open(url)
    }

    static func revealInFinder(_ session: AgentSession) {
        guard let dir = SafeCwd.resolve(session.cwd) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)])
    }

    static func copyHandoff(_ session: AgentSession) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(HandoffBrief.text(session), forType: .string)
    }
}

/// The handoff brief (引継書): distilled so another agent — possibly a
/// different app — can pick up where this session left off. Always derived
/// from the session's current data; never cached.
enum HandoffBrief {
    static func text(_ s: AgentSession) -> String {
        var lines: [String] = []
        lines.append("【ハンドオフ】セッション #\(s.sessionId.prefix(8))「\(s.title)」を引き継ぎます。")
        lines.append("プロジェクト: \(s.project) / ブランチ: \(s.branch ?? "不明") / PR: \(s.prState ?? "未取得")")
        if let cwd = s.cwd { lines.append("作業ディレクトリ: \(cwd)") }
        if let first = s.firstPrompt { lines.append("元の依頼: \(String(first.prefix(600)))") }
        if let last = s.lastAssistant { lines.append("最後のAI出力: \(String(last.prefix(600)))") }
        lines.append("指示: まずリポジトリとこのセッションの現状を確認し、次のステップを提案してから作業を続けてください。")
        return lines.joined(separator: "\n")
    }
}
