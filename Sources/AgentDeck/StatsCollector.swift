import Foundation

// MARK: - 集計結果

/// 日次トークン行。
struct StatsDayRow: Sendable, Equatable {
    let day: String      // yyyy-MM-dd
    let input: Int
    let output: Int
}

struct StatsNameRow: Sendable, Equatable, Identifiable {
    let name: String
    let tokens: Int
    let sessions: Int
    var id: String { name }
}

struct StatsDayCount: Sendable, Equatable, Identifiable {
    let day: String
    let count: Int
    var id: String { day }
}

/// ダッシュボード 1 画面分のスナップショット (値型・スレッド安全)。
struct StatsSnapshot: Sendable {
    var generatedAt = Date()
    var days: [StatsDayRow] = []
    var sessionsPerDay: [StatsDayCount] = []
    var agents: [StatsNameRow] = []
    var projects: [StatsNameRow] = []
    var totalInput = 0
    var totalOutput = 0
    var sessionCount = 0
    var running = 0
    var waiting = 0
    var done = 0
    var failed = 0
    /// 完了/(完了+失敗)。どちらも 0 なら nil。
    var successRate: Double? {
        let d = done + failed
        return d > 0 ? Double(done) / Double(d) : nil
    }
    var avgDurationMin: Double = 0
}

// MARK: - ファイル単位のキャッシュ

/// 1 トランスクリプトファイル分の集計。mtime が変わらない限り再パースしない。
struct StatFileEntry: Codable {
    var mtime: Double = 0
    /// 日付 (yyyy-MM-dd) → [input, output, cacheRead, cacheCreate]
    var days: [String: [Int]] = [:]
    /// ISO タイムスタンプの辞書順比較用 (先頭/最終行)
    var firstTs: String?
    var lastTs: String?
}

// MARK: - コレクタ

/// トランスクリプトからトークン使用量などを集計する。
///
/// - 使い方: `collect { snapshot in ... }` (completion はメインスレッド)。
/// - メタデータ (agent/project/state) はメインスレッドで確定させてから、
///   ファイル解析をユーティリティ優先度のバックグラウンドで行う。
/// - パース結果は mtime 見込みキャッシュし、増分のみ再解析する。
/// - usage 抽出は Claude/Qwen 系の 1 メッセージ毎の usage オブジェクトを
///   対象とする (累積カウンタ形式は二重加算になるため意図的に無視)。
final class StatsCollector: @unchecked Sendable {
    static let shared = StatsCollector()

    private struct Meta: Sendable {
        var path: String
        var agent: String
        var project: String
        var lastActivity: Double
    }

    private let lock = NSLock()
    private var cache: [String: StatFileEntry] = [:]
    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("stats-cache.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.cacheURL),
           let decoded = try? JSONDecoder().decode([String: StatFileEntry].self, from: data) {
            cache = decoded
        }
    }

    private func persist() {
        lock.lock()
        let snapshot = cache
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: Self.cacheURL, options: .atomic)
            }
        }
    }

    /// 集計を実行する。completion は必ずメインスレッドで呼ばれる。
    func collect(completion: @escaping @MainActor @Sendable (StatsSnapshot) -> Void) {
        // 1) メインでメタデータを確定 (store の可変配列を跨ぐ競合を避ける)
        let metas: [Meta] = MainActor.assumeIsolated {
            SessionStore.shared.sessions.map {
                Meta(path: $0.transcriptPath ?? "", agent: $0.agent,
                     project: $0.project, lastActivity: $0.lastActivity.timeIntervalSince1970)
            }
        }
        let stateCounts = MainActor.assumeIsolated {
            (running: SessionStore.shared.sessions.filter { $0.state == .running }.count,
             waiting: SessionStore.shared.sessions.filter { $0.state == .waiting }.count,
             done: SessionStore.shared.sessions.filter { $0.state == .done }.count,
             failed: SessionStore.shared.sessions.filter { $0.state == .failed }.count)
        }
        // 2) バックグラウンドでファイル解析 + 集約
        Task.detached(priority: .utility) { [weak self] in
            let snapshot = self?.aggregate(metas, stateCounts: stateCounts) ?? StatsSnapshot()
            await MainActor.run { completion(snapshot) }
        }
    }

    // MARK: - 内部

    private struct Agg { var tokens = 0; var sessions = 0 }

    private func aggregate(_ metas: [Meta], stateCounts: (running: Int, waiting: Int, done: Int, failed: Int)) -> StatsSnapshot {
        var snap = StatsSnapshot()
        snap.sessionCount = metas.count
        snap.running = stateCounts.running
        snap.waiting = stateCounts.waiting
        snap.done = stateCounts.done
        snap.failed = stateCounts.failed

        var daily: [String: [Int]] = [:]          // day → [in,out,cr,cc]
        var dailySessions: [String: Int] = [:]
        var agentAgg: [String: Agg] = [:]
        var projectAgg: [String: Agg] = [:]
        var durations: [Double] = []

        let fm = FileManager.default
        var dirty = false

        for meta in metas {
            agentAgg[meta.agent, default: Agg()].sessions += 1
            projectAgg[meta.project, default: Agg()].sessions += 1

            var entry: StatFileEntry?
            if !meta.path.isEmpty {
                lock.lock()
                let cached = cache[meta.path]
                lock.unlock()
                let attrs = try? fm.attributesOfItem(atPath: meta.path)
                let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                if let c = cached, c.mtime == mtime {
                    entry = c
                } else if mtime > 0 {
                    if let fresh = Self.parse(path: meta.path, mtime: mtime) {
                        entry = fresh
                        lock.lock()
                        cache[meta.path] = fresh
                        lock.unlock()
                        dirty = true
                    }
                }
            }

            if let e = entry {
                for (day, t) in e.days {
                    daily[day, default: [0, 0, 0, 0]][0] += t[0]
                    daily[day, default: [0, 0, 0, 0]][1] += t[1]
                }
                let tokens = e.days.values.reduce(0) { $0 + $1[0] + $1[1] }
                agentAgg[meta.agent, default: Agg()].tokens += tokens
                projectAgg[meta.project, default: Agg()].tokens += tokens
                snap.totalInput += e.days.values.reduce(0) { $0 + $1[0] }
                snap.totalOutput += e.days.values.reduce(0) { $0 + $1[1] }
                if let f = e.firstTs, let l = e.lastTs, l > f,
                   let fs = Self.seconds(f), let ls = Self.seconds(l), ls > fs {
                    durations.append(ls - fs)
                }
                // セッション開始日 = 初回タイムスタンプの日
                if let f = e.firstTs {
                    let day = String(f.prefix(10))
                    dailySessions[day, default: 0] += 1
                }
            } else {
                // 解析できないセッションも日別セッション数には最終活動日で数える
                let day = Self.dayString(meta.lastActivity)
                dailySessions[day, default: 0] += 1
            }
        }
        if dirty { persist() }

        snap.days = daily.map { StatsDayRow(day: $0.key, input: $0.value[0], output: $0.value[1]) }
            .sorted { $0.day < $1.day }
        snap.sessionsPerDay = dailySessions.map { StatsDayCount(day: $0.key, count: $0.value) }
            .sorted { $0.day < $1.day }
        snap.agents = agentAgg.map { StatsNameRow(name: $0.key, tokens: $0.value.tokens, sessions: $0.value.sessions) }
            .sorted { $0.tokens > $1.tokens }
        snap.projects = projectAgg.map { StatsNameRow(name: $0.key, tokens: $0.value.tokens, sessions: $0.value.sessions) }
            .sorted { $0.tokens > $1.tokens }
        if !durations.isEmpty {
            snap.avgDurationMin = durations.reduce(0, +) / Double(durations.count) / 60.0
        }
        return snap
    }

    // MARK: - パース

    /// 1 ファイルを解析してキャッシュエントリを作る。
    static func parse(path: String, mtime: Double) -> StatFileEntry? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        var entry = StatFileEntry(mtime: mtime)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var start = 0
            for i in 0..<raw.count where raw[i] == 0x0A {
                processLine(raw[start..<i], &entry)
                start = i + 1
            }
            if start < raw.count { processLine(raw[start..<raw.count], &entry) }
        }
        return entry
    }

    private static func processLine<S: Sequence>(_ line: S, _ entry: inout StatFileEntry) where S.Element == UInt8 {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) else { return }
        // 日付: ルートの timestamp 文字列 (ISO8601) の先頭10文字
        var day: String?
        if let dict = obj as? [String: Any], let ts = dict["timestamp"] as? String, ts.count >= 10 {
            let p = String(ts.prefix(10))
            if p.first?.isNumber == true { day = p }
            if entry.firstTs == nil || ts < entry.firstTs! { entry.firstTs = ts }
            if entry.lastTs == nil || ts > entry.lastTs! { entry.lastTs = ts }
        }
        var t = (0, 0, 0, 0)
        collectUsage(obj, into: &t)
        if t.0 > 0 || t.1 > 0 {
            let key = day ?? "unknown"
            let b = entry.days[key, default: [0, 0, 0, 0]]
            entry.days[key] = [b[0] + t.0, b[1] + t.1, b[2] + t.2, b[3] + t.3]
        }
    }

    /// usage 形の辞書 (input_tokens / prompt_tokens 等を持つ) を再帰探索して合算。
    private static func collectUsage(_ node: Any, into t: inout (Int, Int, Int, Int)) {
        switch node {
        case let dict as [String: Any]:
            if let u = dict["usage"] as? [String: Any] {
                addUsage(u, into: &t)
            }
            for (_, v) in dict where !(v is [String: Any] && isUsageDict(v)) {
                collectUsage(v, into: &t)
            }
        case let arr as [Any]:
            for v in arr { collectUsage(v, into: &t) }
        default:
            break
        }
    }

    private static func isUsageDict(_ node: Any) -> Bool {
        guard let d = node as? [String: Any] else { return false }
        return d["usage"] != nil
    }

    private static func addUsage(_ u: [String: Any], into t: inout (Int, Int, Int, Int)) {
        let input = intVal(u, "input_tokens") ?? intVal(u, "prompt_tokens") ?? 0
        let output = intVal(u, "output_tokens") ?? intVal(u, "completion_tokens") ?? 0
        let cr = intVal(u, "cache_read_input_tokens") ?? intVal(u, "cache_read") ?? 0
        let cc = intVal(u, "cache_creation_input_tokens") ?? intVal(u, "cache_creation") ?? 0
        t.0 += input
        t.1 += output
        t.2 += cr
        t.3 += cc
    }

    private static func intVal(_ d: [String: Any], _ k: String) -> Int? {
        if let i = d[k] as? Int { return i }
        if let d2 = d[k] as? Double { return Int(d2) }
        return nil
    }

    private static func seconds(_ iso: String) -> Double? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return d.timeIntervalSince1970 }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)?.timeIntervalSince1970
    }

    private static func dayString(_ unix: Double) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date(timeIntervalSince1970: unix))
    }
}
