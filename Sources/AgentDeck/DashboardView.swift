import SwiftUI
import Charts

/// 統計ダッシュボード (⌘D / メニュー「表示 > ダッシュボード」で開く独立窓)。
/// トークン消費の日次グラフ、エージェント別・プロジェクト別の内訳、
/// セッション統計とライブサマリーを 1 画面にまとめる。
struct DashboardView: View {
    @ObservedObject private var store = SessionStore.shared
    @State private var snapshot = StatsSnapshot()
    @State private var loading = true
    @State private var range: Range = .sevenDays

    enum Range: String, CaseIterable, Identifiable {
        case today, sevenDays = "7日", thirtyDays = "30日", all = "全期間"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .today: return "今日"
            case .sevenDays: return "7日"
            case .thirtyDays: return "30日"
            case .all: return "全期間"
            }
        }
        var daysBack: Int? {
            switch self {
            case .today: return 1
            case .sevenDays: return 7
            case .thirtyDays: return 30
            case .all: return nil
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                summaryCards
                tokenChart
                HStack(alignment: .top, spacing: 18) {
                    agentChart
                    projectList
                }
                sessionStats
                liveSummary
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay { if loading && snapshot.sessionCount == 0 { ProgressView("集計中…") } }
        .task {
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await refresh()
            }
        }
    }

    // MARK: - データ

    private func refresh() async {
        await StatsCollector.shared.collect { snap in
            snapshot = snap
            loading = false
        }
    }

    /// 期間で絞った日次行。
    private var rangedDays: [StatsDayRow] {
        guard let back = range.daysBack else { return snapshot.days }
        let cal = Calendar.current
        let cutoff = cal.startOfDay(for: cal.date(byAdding: .day, value: -(back - 1), to: Date()) ?? Date())
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let cutoffStr = df.string(from: cutoff)
        return snapshot.days.filter { $0.day >= cutoffStr }
    }

    private var rangedSessionsPerDay: [StatsDayCount] {
        guard let back = range.daysBack else { return snapshot.sessionsPerDay }
        let cal = Calendar.current
        let cutoff = cal.startOfDay(for: cal.date(byAdding: .day, value: -(back - 1), to: Date()) ?? Date())
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let cutoffStr = df.string(from: cutoff)
        return snapshot.sessionsPerDay.filter { $0.day >= cutoffStr }
    }

    // MARK: - パーツ

    private var header: some View {
        HStack {
            Text("ダッシュボード").font(.title2).bold()
            Spacer()
            Picker("", selection: $range) {
                ForEach(Range.allCases) { r in Text(r.label).tag(r) }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("再集計")
        }
    }

    private func card(_ title: String, _ value: String, _ sub: String = "", icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3).bold().monospacedDigit()
            if !sub.isEmpty { Text(sub).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var summaryCards: some View {
        let total = rangedDays.reduce(0) { $0 + $1.input + $1.output }
        let sessions = rangedSessionsPerDay.reduce(0) { $0 + $1.count }
        return HStack(spacing: 12) {
            card("トークン (期間)", Self.tok(total), "入力+出力", icon: "bolt.fill")
            card("セッション (期間)", "\(sessions)", "計 \(snapshot.sessionCount) 件", icon: "square.stack.3d.up")
            card("実行中 / 入力待ち", "\(snapshot.running) / \(snapshot.waiting)", "", icon: "circle.dotted")
            card("成功率", snapshot.successRate.map { String(format: "%.0f%%", $0 * 100) } ?? "—",
                 "完了 \(snapshot.done) / 失敗 \(snapshot.failed)", icon: "checkmark.seal")
        }
    }

    private var tokenChart: some View {
        groupBox("日次トークン消費") {
            if rangedDays.isEmpty {
                placeholder("データなし — セッションのトランスクリプトに usage が見つかりません")
            } else {
                Chart {
                    ForEach(rangedDays, id: \.day) { row in
                        BarMark(x: .value("日", String(row.day.suffix(5))), y: .value("トークン", row.input))
                            .foregroundStyle(by: .value("種別", "入力"))
                        BarMark(x: .value("日", String(row.day.suffix(5))), y: .value("トークン", row.output))
                            .foregroundStyle(by: .value("種別", "出力"))
                    }
                }
                .chartForegroundStyleScale([
                    "入力": Color.blue,
                    "出力": Color.orange,
                ])
                .chartLegend(.visible)
                .frame(height: 200)
            }
        }
    }

    private var agentChart: some View {
        groupBox("エージェント別") {
            if snapshot.agents.isEmpty {
                placeholder("データなし")
            } else {
                Chart(snapshot.agents) { a in
                    BarMark(
                        x: .value("トークン", a.tokens),
                        y: .value("エージェント", a.name)
                    )
                    .annotation(position: .trailing) {
                        Text(Self.tok(a.tokens)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .chartXAxis(.hidden)
                .frame(height: CGFloat(max(120, snapshot.agents.count * 28)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var projectList: some View {
        groupBox("プロジェクト TOP5") {
            if snapshot.projects.isEmpty {
                placeholder("データなし")
            } else {
                let top = Array(snapshot.projects.prefix(5))
                let maxTok = max(top.first?.tokens ?? 1, 1)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(top) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(p.name).font(.caption).lineLimit(1)
                                Spacer()
                                Text(Self.tok(p.tokens)).font(.caption2).foregroundStyle(.secondary)
                            }
                            GeometryReader { geo in
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.6))
                                    .frame(width: geo.size.width * CGFloat(p.tokens) / CGFloat(maxTok))
                            }
                            .frame(height: 5)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sessionStats: some View {
        groupBox("セッション統計") {
            HStack(spacing: 24) {
                stat("総セッション", "\(snapshot.sessionCount)")
                stat("実行中", "\(snapshot.running)").foregroundStyle(.green)
                stat("入力待ち", "\(snapshot.waiting)").foregroundStyle(.orange)
                stat("完了", "\(snapshot.done)")
                stat("失敗", "\(snapshot.failed)").foregroundStyle(.red)
                stat("平均所要時間", snapshot.avgDurationMin > 0 ? String(format: "%.0f分", snapshot.avgDurationMin) : "—")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 実行中/入力待ちのライブ一覧。SubAgent は除外。クリックで開く。
    private var liveSummary: some View {
        groupBox("ライブサマリー") {
            let live = store.sessions
                .filter { ($0.state == .running || $0.state == .waiting) && !store.isContainedSubagent($0) }
                .sorted { $0.lastActivity > $1.lastActivity }
            if live.isEmpty {
                placeholder("実行中のセッションはありません")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(live.prefix(12)) { s in
                        Button {
                            HotkeyRouter.shared.fire(.focusSession(s.key))
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(s.state == .running ? Color.green : Color.orange)
                                    .frame(width: 8, height: 8)
                                Text(s.title).lineLimit(1)
                                Spacer()
                                Text(s.agent).font(.caption2).foregroundStyle(.secondary)
                                Text(s.lastActivity, style: .relative)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - 共通パーツ

    private func groupBox(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body).bold().monospacedDigit()
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .center)
    }

    /// トークン数の短縮表記 (1.2M / 340K)。
    static func tok(_ n: Int) -> String {
        switch n {
        case 0..<1_000: return "\(n)"
        case 1_000..<1_000_000: return String(format: "%.1fK", Double(n) / 1_000)
        default: return String(format: "%.2fM", Double(n) / 1_000_000)
        }
    }
}
