import Foundation

/// Queued on-device FM summarization for session cards. Runs a couple of
/// jobs at a time so the board doesn't fire one LanguageModelSession per card
/// simultaneously; results land in SummaryCache (shared with the detail
/// panel's 履歴 tab). Never blocks the UI; skips when FM is unavailable.
@MainActor
final class CardSummarizer {
    static let shared = CardSummarizer()

    private struct Job {
        let key: String
        let path: String
        let mtime: Date
        let onReady: (String, Date) -> Void
    }

    private var queue: [Job] = []
    private var inflight = 0
    private let maxConcurrent = 2

    func ensure(key: String, path: String?, mtime: Date, onReady: @escaping (String, Date) -> Void) {
        guard let path, FMService.shared.isAvailable else { return }
        if SummaryCache.get(key, mtime: mtime) != nil { return }
        guard !queued(key: key) else { return }
        queue.append(Job(key: key, path: path, mtime: mtime, onReady: onReady))
        pump()
    }

    private func queued(key: String) -> Bool {
        queue.contains { $0.key == key }
    }

    private func pump() {
        guard inflight < maxConcurrent, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        inflight += 1
        let compressed = TranscriptReader.turns(path: job.path, limit: 60)
            .map { turn in
                let cap = turn.role == "user" ? 250 : 200
                return "\(turn.role == "user" ? "ユーザー" : "AI"): \(String(turn.text.prefix(cap)))"
            }
            .joined(separator: "\n")
        guard !compressed.isEmpty else {
            inflight -= 1
            pump()
            return
        }
        let key = job.key
        let mtime = job.mtime
        Task {
            let result = await FMService.shared.summarize(transcript: compressed)
            SummaryCache.set(key, mtime: mtime, result)
            job.onReady(result, mtime)
            inflight -= 1
            pump()
        }
    }
}