import Foundation

/// Enriches sessions with external ground truth (git/gh) and on-device
/// first-turn gists. Runs async, once per session, fail-open.
final class Enricher: @unchecked Sendable {
    static let shared = Enricher()

    private let lock = NSLock()
    private var inflight = Set<String>()
    /// Enrichment runs blocking subprocesses (git/tmux/gh), so it happens on a
    /// dedicated utility queue, capped at 6 concurrent — a startup rescan must
    /// never fork hundreds of processes at once.
    private let queue = DispatchQueue(label: "agentdeck.enricher", qos: .utility)
    private let gate = DispatchSemaphore(value: 6)

    func enrich(_ info: TranscriptInfo) {
        let key = "\(info.agent):\(info.sessionId)"
        lock.lock()
        guard !inflight.contains(key) else { lock.unlock(); return }
        inflight.insert(key)
        lock.unlock()

        queue.async {
            defer { self.gate.signal() }
            self.gate.wait()
            guard let cwd = SafeCwd.resolve(info.cwd) else { return }
            var branch = info.gitBranch
            if branch == nil || branch?.isEmpty == true {
                branch = GitProbe.currentBranch(cwd: cwd)
            }
            let tmux = TmuxProbe.liveSession(cwd: cwd)
            var pr: PRInfo?
            if let branch, !branch.isEmpty {
                pr = Self.prInfo(cwd: cwd, branch: branch)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    SessionStore.shared.applyEnrichment(
                        key: key, prState: pr?.state, prNumber: pr?.number, tmux: tmux, branch: branch)
                }
            }
        }
    }

    struct PRInfo: Sendable {
        let state: String
        let number: Int?
    }

    /// e.g. "MERGED 3768" / "OPEN 3770" / "none" — via `gh` in the session's cwd.
    static func prInfo(cwd: String, branch: String) -> PRInfo {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [
            "-l", "-c",
            "gh pr view \(shellQuote(branch)) --json state,number -q '.state + \" \" + (.number | tostring)'",
        ]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return PRInfo(state: "none", number: nil)
        }
        guard p.terminationStatus == 0 else { return PRInfo(state: "none", number: nil) }
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = s.split(separator: " ")
        guard let first = parts.first, !first.isEmpty else { return PRInfo(state: "none", number: nil) }
        return PRInfo(state: String(first), number: parts.count > 1 ? Int(parts[1]) : nil)
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Detects a live qwen-tmux session for a cwd. tmux allows multiple
/// concurrent attaches, so the deck can mirror a terminal that is already
/// running elsewhere — real-time view AND input from both sides.
enum TmuxProbe {
    /// Short-lived memo (TTL = 5s) keyed by resolved cwd. A probe forks a
    /// shell and runs git+tmux, so repeated opens must not re-pay that cost;
    /// the Enricher scan and the panel/terminal opens share one answer.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (name: String?, at: Date)] = [:]
    private static let ttl: TimeInterval = 5

    /// Mirrors ~/bin/qwen-tmux naming: basename of git toplevel, ' .:' → '-'.
    /// Returns nil both for "no live tmux" and "not probed yet / expired";
    /// callers treat nil as "assume plain resume".
    static func liveSession(cwd: String?) -> String? {
        guard let resolved = SafeCwd.resolve(cwd) else { return nil }
        lock.lock()
        if let hit = cache[resolved], Date().timeIntervalSince(hit.at) < ttl {
            lock.unlock()
            return hit.name
        }
        lock.unlock()
        let name = probe(resolved)
        lock.lock()
        cache[resolved] = (name, Date())
        lock.unlock()
        return name
    }

    /// Lightweight probe: **no login shell** (`-l` dropped) — a profile load
    /// is pure overhead for git/tmux — with Homebrew/usr/local prepended to
    /// PATH so the binaries resolve on Apple Silicon.
    private static func probe(_ cwd: String) -> String? {
        let q = shellQuote(cwd)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c",
            "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH; " +
            "n=$(git -C \(q) rev-parse --show-toplevel 2>/dev/null || echo \(q)); " +
            "n=$(basename \"$n\" | tr ' .:' '---'); " +
            "tmux has-session -t \"=$n\" 2>/dev/null && printf '%s' \"$n\""]
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
        let name = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
