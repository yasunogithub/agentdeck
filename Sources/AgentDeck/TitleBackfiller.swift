import Foundation

/// Persisted FM-generated titles (first prompts never change, so no invalidation).
enum TitleCache {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agentdeck/titles.json")

    private static let lock = NSLock()
    nonisolated(unsafe) private static var store: [String: String] = load()

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    static func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return store[key]
    }

    static func set(_ key: String, _ title: String) {
        lock.lock()
        store[key] = title
        let snapshot = store
        lock.unlock()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
}

/// User-chosen titles. Highest precedence: a manual rename must survive
/// rescans, AI backfill and transcript-derived ai-titles.
enum RenameCache {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agentdeck/renames.json")

    private static let lock = NSLock()
    nonisolated(unsafe) private static var store: [String: String] = load()

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    static func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return store[key]
    }

    static func set(_ key: String, _ title: String) {
        lock.lock()
        store[key] = title
        let snapshot = store
        lock.unlock()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
}

/// Serially generates FM titles for sessions lacking a native one (qwen etc.),
/// including a startup backfill over all scanned sessions. On-device, ~0.3s each.
@MainActor
final class TitleBackfiller {
    static let shared = TitleBackfiller()

    private var queue: [(key: String, prompt: String)] = []
    private var running = false
    private var seen = Set<String>()

    func enqueue(_ key: String, _ prompt: String) {
        guard !seen.contains(key) else { return }
        seen.insert(key)
        queue.append((key, prompt))
        pump()
    }

    private func pump() {
        guard !running, !queue.isEmpty else { return }
        running = true
        let item = queue.removeFirst()
        Task {
            if let t = await FMService.shared.title(forFirstPrompt: item.prompt) {
                TitleCache.set(item.key, t)
                SessionStore.shared.setTitle(key: item.key, t)
            }
            try? await Task.sleep(for: .milliseconds(300))
            self.running = false
            self.pump()
        }
    }
}
