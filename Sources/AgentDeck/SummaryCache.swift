import Foundation

/// Persistent summary cache (survives restarts; invalidated by transcript mtime).
enum SummaryCache {
    struct Entry: Codable {
        var mtime: Date
        var text: String
    }

    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agentdeck/summaries.json")

    private static let lock = NSLock()
    nonisolated(unsafe) private static var store: [String: Entry] = load()

    private static func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    static func get(_ key: String, mtime: Date) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let e = store[key], e.mtime == mtime else { return nil }
        return e.text
    }

    static func set(_ key: String, mtime: Date, _ text: String) {
        lock.lock()
        store[key] = Entry(mtime: mtime, text: text)
        let snapshot = store
        lock.unlock()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
}
