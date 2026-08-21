import SwiftUI
import AppKit

enum SidebarSelection: Hashable {
    case all
    case archive
    /// 入力待ち+実行中+失敗 をまとめた「アクティブ」ビュー。
    case active
    case state(SessionState)
    case agent(String)
    case project(String)
}

struct BoardView: View {
    @ObservedObject private var store = SessionStore.shared
    @ObservedObject private var ui = UISettings.shared
    @ObservedObject private var router = HotkeyRouter.shared
    @ObservedObject private var dictation = DictationService.shared
    /// Session currently bound to the right panel / active terminal. This is
    /// intentionally independent from the browsing cursor below.
    @State private var selected: AgentSession?
    /// Browsing cursor changed by j/k, arrows, and clicks; it never mounts a
    /// terminal on its own.
    @State private var selection: String?
    @State private var panelTab: RightPanelTab = .terminal
    /// Collapsed hides the panel and dismantles any embedded PTY.
    @State private var panelCollapsed = false
    /// Launch mode per session key — the async tmux probe may upgrade
    /// resume → attach before the terminal is mounted.
    @State private var panelModes: [String: TerminalMode] = [:]
    /// Terminal activation is explicit. While false the panel may show a
    /// probe placeholder, but it never mounts a PTY.
    @State private var terminalReady = false
    @State private var probeGeneration = 0
    @State private var query = ""
    /// Finder-style type-ahead: bare printable keys append here and narrow
    /// the session list by prefix. Auto-clears after 2s of no typing.
    @State private var typeAhead = ""
    @State private var typeAheadGen = 0
    @State private var sidebar: SidebarSelection? = .all
    @Environment(\.openWindow) private var openWindow
    @FocusState private var boardFocused: Bool
    @FocusState private var searchFocused: Bool
    @State private var renamingKey: String?
    @State private var renameDraft = ""
    /// Session whose AI title rename modal is open.
    @State private var aiRenameTarget: AgentSession?
    @FocusState private var sidebarFocused: Bool
    @State private var region: FocusRegion = .board
    /// Vim-style `gg` detection (double-g within 400ms jumps to top).
    @State private var lastG: Double = 0

    enum FocusRegion: Int, CaseIterable {
        case board, search, sidebar
    }

    // MARK: filtering

    private var baseSessions: [AgentSession] {
        store.sessions.filter { session in
            guard store.shouldShowOnBoard(session) else { return false }
            guard let parentID = session.parentID else { return true }
            // SubAgent セッションは親カードに内包して折りたたみ表示するので
            // トップレベルには並ばない。親がボードに居ない (アーカイブ済み/
            // 未認識) 子は行き場がないのでトップレベルに残す。
            guard let parent = store.sessions.first(where: { $0.key == parentID }) else { return true }
            return !store.shouldShowOnBoard(parent)
        }
    }

    /// Inactive 昨日 00:00 より前 (any state): hidden from the live board and
    /// the counts, browsable in アーカイブ.
    private var archivedSessions: [AgentSession] {
        store.sessions.filter { store.isArchived($0) }
    }

    private var visible: [AgentSession] {
        if sidebar == .archive {
            var list = archivedSessions
            if !query.isEmpty { list = list.filter { $0.matches(query) } }
            if !typeAhead.isEmpty { list = list.filter { $0.matches(typeAhead) } }
            return sorted(list)
        }
        var list = baseSessions
        switch sidebar {
        case .active:
            list = list.filter { $0.state == .waiting || $0.state == .running || $0.state == .failed }
        case .state(let s): list = list.filter { $0.state == s }
        case .agent(let a): list = list.filter { $0.agent == a }
        case .project(let p): list = list.filter { $0.project == p }
        case .all, .archive, nil: break
        }
        if !query.isEmpty { list = list.filter { $0.matches(query) } }
        if !typeAhead.isEmpty { list = list.filter { $0.matches(typeAhead) } }
        return sorted(list)
    }

    /// デフォルト並び替え = 最新更新順 (lastActivity desc)。
    /// 同一時刻内は 入力待ち → 実行中 → 失敗 → 完了 → アイドル の順
    /// (sortRank) で安定。最近やったことが常に上に来る。
    private func sorted(_ list: [AgentSession]) -> [AgentSession] {
        list.sorted { a, b in
            if a.lastActivity != b.lastActivity { return a.lastActivity > b.lastActivity }
            if a.state.sortRank != b.state.sortRank { return a.state.sortRank < b.state.sortRank }
            return a.key < b.key
        }
    }

    private func count(_ s: SessionState) -> Int { baseSessions.filter { $0.state == s }.count }
    /// 入力待ち+実行中+失敗 = 「アクティブ」行の数。
    private var activeCount: Int {
        baseSessions.filter { $0.state == .waiting || $0.state == .running || $0.state == .failed }.count
    }
    private var agents: [(String, Int)] {
        Dictionary(grouping: baseSessions, by: \.agent).map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
    }
    /// プロジェクト欄: 「最近」= 直近 (今日+昨日) にアクティブなプロジェクト、
    /// 「過去」= それより前のセッションしかないプロジェクト。古いプロジェクトも
    /// 消えず「過去」に残る。
    private var recentProjects: [(String, Int)] { projectSections().recent }
    private var pastProjects: [(String, Int)] { projectSections().past }
    private var projects: [(String, Int)] { recentProjects + pastProjects }

    private func projectSections() -> (recent: [(String, Int)], past: [(String, Int)]) {
        let hidden = ProjectStore.shared.hidden
        let cutoff = SessionStore.boardCutoff
        let manualNames = Set(ProjectStore.shared.manual.map(\.name))
        let groups = Dictionary(grouping: store.sessions.filter { !hidden.contains($0.project) }, by: \.project)
        var recent: [(name: String, count: Int, last: Date)] = []
        var past: [(name: String, count: Int, last: Date)] = []
        for (name, sessions) in groups {
            let count = baseSessions.filter { $0.project == name }.count
            let lastActive = sessions.map(\.lastActivity).max() ?? .distantPast
            if manualNames.contains(name) || lastActive >= cutoff {
                recent.append((name, count, lastActive))
            } else {
                past.append((name, count, lastActive))
            }
        }
        // Deterministic order: count desc → last activity desc → name, so the
        // list never shuffles between recomputes (Dictionary order + unstable
        // sort would reorder equal-count projects on every update).
        recent.sort {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.last != $1.last { return $0.last > $1.last }
            return $0.name < $1.name
        }
        recent = Array(recent.prefix(12))
        let names = Set(recent.map(\.name))
        for m in ProjectStore.shared.manual where !names.contains(m.name) {
            recent.append((m.name, 0, .distantPast))
        }
        past.sort {
            if $0.last != $1.last { return $0.last > $1.last }
            return $0.name < $1.name
        }
        return (recent.map { ($0.name, $0.count) }, Array(past.prefix(12)).map { ($0.name, $0.count) })
    }

    var body: some View {
        stateTrackers
            .onKeyPress(phases: .down) { press in
                boardKey(press)
            }
            .onReceive(HotkeyRouter.shared.events) { handle($0) }
            .sheet(item: $aiRenameTarget) { target in
                AITitleRenameSheet(session: target) { title in
                    store.rename(key: target.key, title)
                }
            }
    }

    /// HStack layout + appearance/focus/overlay modifiers. Split out of the
    /// `body` modifier chain so each intermediate view type-checks promptly.
    private var boardLayout: some View {
        HStack(spacing: 0) {
            sidebarView
                .frame(width: ui.sidebarWidth)
                .listStyle(.sidebar)
                .focused($sidebarFocused)
                .onChange(of: sidebarFocused) { _, _ in syncKeyGate() }
            PanelResizeDivider(width: $ui.sidebarWidth, range: 160...420, growWithRightDrag: true)
            Divider()
            boardPane
            if let current = selected {
                if !panelCollapsed {
                    Divider()
                    PanelResizeDivider(width: $ui.panelWidth)
                }
                SessionRightPanel(
                    session: current,
                    tab: $panelTab,
                    mode: panelModes[current.key] ?? .resume,
                    terminalReady: terminalReady,
                    onClose: collapsePanel,
                    active: !panelCollapsed
                )
                .frame(width: panelCollapsed ? 0 : ui.panelWidth)
                .clipped()
                .allowsHitTesting(!panelCollapsed)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($boardFocused)
        .overlay(alignment: .top) { ErrorBanner() }
        .overlay(alignment: .topTrailing) {
            ErrorDot().padding(.top, 14).padding(.trailing, 20)
        }
        .windowTransparency(ui.mainOpacity)
        .onAppear {
            focusBoard()
            // macOS may hand initial focus to the first focusable control
            // (the search field) AFTER onAppear; re-assert board focus once
            // a beat later — unless the user already went into search.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                guard !searchFocused else { return }
                focusBoard()
            }
        }
        // ⌘K パレットはスポットライト式フローティングパネル
        // (PalettePanelController) が全窓共通で表示するため、ここには
        // overlay を置かない。
        // キーモニタ (AppKit 側) からダッシュボードを開けるよう入口を公開。
        // openWindow は Environment 依存なので、起動時に必ず走る BoardView
        // の onAppear で差し込む。
        .onAppear {
            GlobalWindowActions.openDashboard = { openWindow(id: "dashboard") }
        }
        .overlay(alignment: .top) {
            if dictation.active {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .foregroundStyle(.red)
                    Text(dictation.interim.isEmpty ? "音声入力中… ⌘⌘ で確定" : dictation.interim)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.red.opacity(0.35)))
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    /// All store/focus/panel observers applied to the layout. Kept separate
    /// so the type-checker resolves the chain in two hops instead of one.
    private var stateTrackers: some View {
        focusTrackers
            .onChange(of: panelTab) { _, newTab in self.panelTabChanged(newTab) }
            .onChange(of: panelCollapsed) { _, _ in self.syncPanelGate() }
            .onChange(of: sidebar) { _, _ in self.sidebarChanged() }
            .onChange(of: sidebar) { _, _ in self.sidebarFocusRestore() }
    }

    /// Focus-related observers only — the other half of the onChange chain.
    private var focusTrackers: some View {
        boardLayout
        .onChange(of: router.paletteOpen) { _, open in self.paletteChanged(open: open) }
        // The search gate must track focus *losses* too: once ⌘F focused the
        // field, leaving it (clicking a card, opening the palette, …) must
        // re-enable board keys and never leave the field holding focus.
        .onChange(of: searchFocused) { _, _ in self.syncKeyGate() }
        .onChange(of: renamingKey) { _, key in self.renamingChanged(key: key) }
        .onChange(of: aiRenameTarget?.key) { _, key in
            KeyGate.suppressBoardKeys = key != nil
        }
    }

    /// Clicking a sidebar row must never trap keyboard focus in the List:
    /// hand focus back to the board so j/k, Return and type-ahead keep
    /// working the moment after the click. (Tab-cycling to the sidebar
    /// doesn't change `sidebar`, so it is unaffected.)
    private func sidebarFocusRestore() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            focusBoard()
        }
    }

    private func paletteChanged(open: Bool) {
        // Give focus back to the board only when the embedded terminal
        // isn't the responder — the key monitor already restored it.
        if !open, !(NSApp.keyWindow?.firstResponder is TranslucentTerminalView) {
            focusBoard()
        }
    }

    private func renamingChanged(key: String?) {
        syncKeyGate()
        if key == nil { focusBoard() }
    }

    private func panelTabChanged(_ newTab: RightPanelTab) {
        syncPanelGate()
        guard newTab == .terminal, let s = selected else { return }
        mountTerminal(s)
    }

    private func sidebarChanged() {
        guard selected != nil else { return }
        if let cur = selected, visible.contains(where: { $0.key == cur.key }) { return }
        if let top = visible.first, top.key != selection {
            selection = top.key
        }
    }

    private func handle(_ h: Hotkey) {
        switch h {
        case .search:
            // The sidebar List can win the focus race against the search
            // field; drop it first, then re-assert after a beat (SwiftUI
            // focus races the split view).
            sidebarFocused = false
            searchFocused = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                searchFocused = true
            }
        case .openTerminal: openTerminalForSelection()
        case .openDetail: openDetailForSelection()
        case .handoff: openHandoffForSelection()
        case .toggleHistory: store.showHistory.toggle()
        case .rescan: TranscriptScanner.shared.rescan()
        case .newTerminal: openBareTerminal(nil)
        case .palette: router.togglePalette()
        case .sidebarAll: sidebar = .all
        case .sidebarArchive: sidebar = .archive
        case .sidebarActive: sidebar = .active
        case .sidebarRunning: sidebar = .state(.running)
        case .sidebarWaiting: sidebar = .state(.waiting)
        case .sidebarFailed: sidebar = .state(.failed)
        case .sidebarDone: sidebar = .state(.done)
        case .sidebarIdle: sidebar = .state(.idle)
        case .cycleProject: cycleProjects()
        case .moveNext: _ = move(1)
        case .movePrev: _ = move(-1)
        case .goFirst:
            if let first = visible.first { selection = first.key }
        case .goLast:
            if let last = visible.last { selection = last.key }
        case .rename: startRename(selection ?? visible.first?.key)
        case .back: togglePanel()
        case .focusNext: cycleRegion(1)
        case .focusPrev: cycleRegion(-1)
        case .typeFilter(let s): appendTypeAhead(s)
        case .openTerminalSpec(let spec): openWindow(id: "terminal", value: spec)
        case .reopenLastTerminal: _ = TerminalWindowState.shared.reopenLast()
        case .focusSession(let key):
            // 通知クリック・パレット: そのセッションを right panel で開く。
            // ターミナル窓などから呼ばれるため、ボード窓を必ず前面に出す。
            if let s = store.sessions.first(where: { $0.key == key }) {
                let boardWin = NSApp.windows.first {
                    $0.isVisible && ($0.title.isEmpty || $0.title == "AgentDeck")
                } ?? NSApp.windows.first {
                    $0.title.isEmpty || $0.title == "AgentDeck"
                }
                boardWin?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                openSession(s)
            }
        case .archive: sidebar = sidebar == .archive ? .all : .archive
        case .goMain:
            typeAhead = ""
            focusBoard()
        case .panelHide: collapsePanel()
        case .panelShow:
            if selected == nil {
                if let s = visible.first { openSession(s) }
            } else if panelCollapsed {
                panelCollapsed = false
                if panelTab == .terminal { scheduleTerminalFocus() } else { focusBoard() }
            }
        }
    }

    private var currentProject: String? {
        if case .project(let p) = sidebar { return p }
        return nil
    }

    private func cycleProjects() {
        let list = projects.map(\.0)
        guard !list.isEmpty else { return }
        let cur = currentProject
        if let cur, let i = list.firstIndex(of: cur) {
            sidebar = .project(list[(i + 1) % list.count])
        } else {
            sidebar = .project(list[0])
        }
    }

    /// Tab cycles board → header → sidebar so every region is reachable
    /// without the mouse; arrows/jk keep moving the selection inside a region.
    private func cycleRegion(_ delta: Int) {
        if renamingKey != nil { commitRename() }
        let all = FocusRegion.allCases
        let next = (region.rawValue + delta + all.count) % all.count
        region = all[next]
        boardFocused = region == .board
        searchFocused = region == .search
        sidebarFocused = region == .sidebar
        syncKeyGate()
    }

    // MARK: sidebar

    private var sidebarView: some View {
        List(selection: $sidebar) {
            Section {
                SidebarRow(label: "すべて", systemImage: "square.grid.2x2", count: baseSessions.count)
                    .tag(SidebarSelection.all)
                SidebarRow(label: "アーカイブ", systemImage: "archivebox", count: archivedSessions.count)
                    .tag(SidebarSelection.archive)
            }
            // アクティブ優先: 見るべき状態が上、完了系は下のセクションに隔離。
            Section("アクティブ") {
                SidebarRow(label: "アクティブ", color: .accentColor, count: activeCount, emphasized: true)
                    .tag(SidebarSelection.active)
                ForEach([SessionState.waiting, .running, .failed], id: \.self) { s in
                    SidebarRow(label: s.label, color: s.color, count: count(s))
                        .tag(SidebarSelection.state(s))
                }
            }
            Section("完了") {
                SidebarRow(label: "完了", systemImage: "checkmark.circle", count: count(.done))
                    .tag(SidebarSelection.state(.done))
                SidebarRow(label: "アイドル", systemImage: "moon.zzz", count: count(.idle))
                    .tag(SidebarSelection.state(.idle))
            }
            if !agents.isEmpty {
                Section("エージェント") {
                    ForEach(agents, id: \.0) { a in
                        SidebarRow(label: a.0, systemImage: "terminal", count: a.1)
                            .tag(SidebarSelection.agent(a.0))
                    }
                }
            }
            Section {
                ForEach(recentProjects, id: \.0) { projectRow($0) }
            } header: {
                HStack {
                    Text("最近")
                    Spacer()
                    Menu {
                        Button("フォルダを追加…") { addProjectFlow() }
                        Button("新規ターミナルを開く…") { openBareTerminalPicker() }
                        if !ProjectStore.shared.hidden.isEmpty {
                            Divider()
                            ForEach(ProjectStore.shared.hidden.sorted(), id: \.self) { h in
                                Button("\(h) を表示に戻す") { ProjectStore.shared.unhide(h) }
                            }
                        }
                    } label: {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("プロジェクト/フォルダの追加・管理")
                }
            }
            Section("過去") {
                ForEach(pastProjects, id: \.0) { projectRow($0) }
            }
        }
        .listStyle(.sidebar)
        .focused($sidebarFocused)
        .onChange(of: sidebarFocused) { _, _ in syncKeyGate() }
    }

    private func projectRow(_ p: (String, Int)) -> some View {
        SidebarRow(label: p.0, systemImage: "folder", count: p.1)
            .tag(SidebarSelection.project(p.0))
            .contextMenu {
                Button("新規ターミナルを開く") { openBareTerminal(cwd(forProject: p.0)) }
                Button("Finderで開く") {
                    if let dir = SafeCwd.resolve(cwd(forProject: p.0)) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)])
                    }
                }
                Divider()
                if ProjectStore.shared.manual.contains(where: { $0.name == p.0 }) {
                    Button("プロジェクトから削除") { ProjectStore.shared.removeManual(p.0) }
                } else {
                    Button("サイドバーから非表示") { ProjectStore.shared.hide(p.0) }
                }
            }
    }

    // MARK: board pane

    private var boardPane: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            Group {
                if sidebar == .archive {
                    archiveList
                } else if store.sessions.isEmpty {
                    emptyState
                } else {
                    sessionList
                }
            }
            .safeAreaInset(edge: .bottom) { statusBar }
        }
        .toolbar { toolbarContent }
        // Terminal focus leaves the board; clicking empty board space hands
        // keyboard focus (and j/k nav) back without closing the panel.
        .contentShape(Rectangle())
        .onTapGesture { focusBoard() }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            TextField("検索 (⌘F)", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit {
                    if let top = visible.first { selection = top.key }
                    focusBoard()
                }
                .onExitCommand {
                    query = ""
                    focusBoard()
                }
            if !typeAhead.isEmpty {
                HStack(spacing: 4) {
                    Text("絞り込み: \(typeAhead)")
                    Button {
                        typeAhead = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                .transition(.scale.combined(with: .opacity))
            }
            if !query.isEmpty {
                Button {
                    query = ""
                    focusBoard()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                TranscriptScanner.shared.rescan()
            } label: {
                Label("再スキャン", systemImage: "arrow.clockwise")
            }
            .help("transcriptを再スキャン (⌘R)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                togglePanel()
            } label: {
                Label("右パネル", systemImage: "sidebar.right")
            }
            .help("右パネルを表示/非表示（←/h）")
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $store.showHistory) {
                Label("履歴", systemImage: "clock.arrow.circlepath")
            }
            .toggleStyle(.button)
            .help("昨日より前のセッションも表示する (⌘⇧H)")
        }
    }

    private func stateChip(_ s: SessionState) -> some View {
        HStack(spacing: 4) {
            Circle().fill(s.color).frame(width: 7, height: 7)
            Text("\(count(s))").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("セッションはまだありません")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(visible) { session in
                        cardRow(session)
                    }
                }
                .padding(10)
            }
            .onChange(of: selection) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    /// 1行のセッションカード: 本体 + ダブルクリック/クリック/コンテキスト
    /// メニュー。巨大な式を関数に切り出して型チェックを軽くしている。
    @ViewBuilder
    private func cardRow(_ session: AgentSession) -> some View {
        let subCount = store.sessions.filter { $0.parentID == session.key && store.shouldShowOnBoard($0) }.count
        SessionCard(
            session: session,
            isSelected: session.key == selection,
            subagentCount: subCount,
            isRenaming: renamingKey == session.key,
            renameText: $renameDraft,
            onRenameCommit: commitRename,
            onRenameCancel: { renamingKey = nil }
        )
        .id(session.key)
        .contextMenu { cardMenu(session) }
        .onTapGesture(count: 2) {
            // Escape hatch: a full separate terminal window.
            selection = session.key
            openTerminal(for: session)
        }
        .onTapGesture {
            // クリックで右パネルをこのセッションにバインド
            // (実行中/入力待ち=ターミナル、完了/失敗=詳細)。
            // ⏎と同じ openSession なので、クリックだけで
            // 左→右の流れが1アクションで完結する。
            selection = session.key
            openSession(session)
        }
    }

    /// SubAgent セッションは親カードに内包のみ。リストのアイテムとしては
    /// 表示しない (親カードの ≀N チップと詳細ビューで確認できる)。
    @ViewBuilder
    private func cardMenu(_ session: AgentSession) -> some View {
        Button("リネーム") { startRename(session.key) }
        Button("AIでタイトル生成…") { aiRenameTarget = session }
        Button("右パネルで開く") { openSession(session) }
        Divider()
        if store.isArchived(session) {
            Button("アーカイブから戻す") { unarchiveSession(session) }
        } else {
            Button("アーカイブ") { archiveSession(session) }
        }
        Divider()
        Button("引継書をコピー") { RepoTools.copyHandoff(session) }
        Button("Finderで開く") { RepoTools.revealInFinder(session) }
        Button("GitHubで開く") { RepoTools.openPR(session) }
        Divider()
        Button("詳細を開く") { openDetailTab(session) }
        Button("別エージェントへ引き継ぐ…") { openHandoffTab(session) }
        Button("ライブattach (tmux)") {
            openAttachWindow(for: session)
        }
        .disabled(session.tmuxSession == nil)
        Button("resumeターミナルを開く") {
            openTerminalWindow(for: session)
        }
        Button("新規セッションへハンドオフ") {
            openWindow(id: "terminal", value: "handoff:\(session.key)")
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle().fill(.green).frame(width: 7, height: 7)
            Text("daemon :\(EventServer.port)")
                .font(.caption).foregroundStyle(.secondary)
            stateChip(.waiting)
            stateChip(.running)
            stateChip(.failed)
            stateChip(.done)
            Label(FMService.shared.isAvailable ? "FM" : "FM off", systemImage: "brain")
                .font(.caption2)
                .foregroundStyle(FMService.shared.isAvailable ? .green : .secondary)
            Spacer()
            Text("クリック/⏎=右パネル(実行中=ターミナル/完了=詳細) →/l=詳細 ←/h=非表示 ⌘1=Mainへ 1-6=サイドバー(3=アクティブ) p=プロジェクト ⌘K=パレット ⌘T=新規ターミナル ⌘+/⌘-=そのPaneのフォント拡縮 ⌘0=リセット ⌘⌘=音声 スワイプ←=非表示/→=表示")
                .font(.caption2).foregroundStyle(.tertiary)
            Text("\(visible.count)/\(store.sessions.count)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: keyboard actions

    /// The whole board key dispatcher, extracted from the onKeyPress body so
    /// the giant switch type-checks promptly on every build.
    private func boardKey(_ press: KeyPress) -> KeyPress.Result {
        // A text field (search/rename/detail input) or the embedded terminal
        // holds the real responder: the monitor already lets these events
        // through, so board keys must not ALSO act on them.
        guard !KeyGate.suppressBoardKeys else { return .ignored }
        // SwiftTerm's terminal views live outside SwiftUI's focus graph,
        // so onKeyPress can fire on shell keys. Match by class name to
        // avoid importing SwiftTerm (its `Color` clashes with SwiftUI).
        if let fr = NSApp.keyWindow?.firstResponder,
           String(describing: type(of: fr)).contains("TerminalView") {
            return .ignored
        }
        if press.modifiers.contains(.command) && press.modifiers.contains(.shift) {
            switch press.key {
            case KeyEquivalent("a"): handle(.archive); return .handled
            case KeyEquivalent("n"): handle(.handoff); return .handled
            case KeyEquivalent("h"): handle(.toggleHistory); return .handled
            case KeyEquivalent("t"): handle(.reopenLastTerminal); return .handled
            default: return .ignored
            }
        }
        if press.modifiers.contains(.command) {
            switch press.key {
            case KeyEquivalent("f"): handle(.search); return .handled
            case KeyEquivalent("k"): handle(.palette); return .handled
            case KeyEquivalent("t"): handle(.newTerminal); return .handled
            case KeyEquivalent("r"): handle(.rescan); return .handled
            case KeyEquivalent("1"): handle(.goMain); return .handled
            case KeyEquivalent("="), KeyEquivalent("+"):
                UISettings.shared.zoomMain(1); return .handled
            case KeyEquivalent("-"):
                UISettings.shared.zoomMain(-1); return .handled
            case KeyEquivalent("0"):
                let ui = UISettings.shared
                ui.zoomMain(-ui.mainZoom)
                return .handled
            case .return: handle(.openDetail); return .handled
            default: return .ignored
            }
        }
        // ⌃/⌥ combos (⌃⇧L etc.) are for the terminal, the input method
        // or apps inside it — never for bare board keys.
        if press.modifiers.contains(.control) || press.modifiers.contains(.option) {
            return .ignored
        }
        // Detail tab is showing: board nav keys must not act behind the
        // panel (its controls keep Return/Tab/arrows natively).
        if KeyGate.detailPanelActive {
            switch press.key {
            case .return, .tab, .escape, .upArrow, .downArrow, .leftArrow, .rightArrow,
                 KeyEquivalent("1"), KeyEquivalent("2"), KeyEquivalent("3"), KeyEquivalent("4"),
                 KeyEquivalent("5"), KeyEquivalent("6"), KeyEquivalent("p"),
                 KeyEquivalent("x"), KeyEquivalent("g"), KeyEquivalent("j"), KeyEquivalent("k"),
                 KeyEquivalent("l"), KeyEquivalent("h"), KeyEquivalent("r"):
                return .ignored
            default: break
            }
        }
        switch press.key {
        case .return: handle(.openTerminal); return .handled
        case KeyEquivalent("1"): handle(.sidebarAll); return .handled
        case KeyEquivalent("2"): handle(.sidebarArchive); return .handled
        case KeyEquivalent("3"): handle(.sidebarActive); return .handled
        case KeyEquivalent("4"): handle(.sidebarDone); return .handled
        case KeyEquivalent("5"): handle(.sidebarIdle); return .handled
        case KeyEquivalent("6"): handle(.sidebarFailed); return .handled
        case KeyEquivalent("p"): handle(.cycleProject); return .handled
        case KeyEquivalent("x"): handle(.sidebarAll); return .handled
        case KeyEquivalent("g"): return plainKeyG(press)
        case .tab:
            handle(press.modifiers.contains(.shift) ? .focusPrev : .focusNext)
            return .handled
        case .rightArrow: handle(.openDetail); return .handled
        case .leftArrow: handle(.back); return .handled
        case .upArrow: handle(.movePrev); return .handled
        case .downArrow: handle(.moveNext); return .handled
        case KeyEquivalent("j"): handle(.moveNext); return .handled
        case KeyEquivalent("k"): handle(.movePrev); return .handled
        case KeyEquivalent("l"): handle(.openDetail); return .handled
        case KeyEquivalent("h"): handle(.back); return .handled
        case KeyEquivalent("r"): handle(.rename); return .handled
        case .escape:
            typeAhead = ""
            focusBoard()
            return .handled
        default: return .ignored
        }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !visible.isEmpty else { return .handled }
        let idx = visible.firstIndex { $0.key == selection } ?? (delta > 0 ? -1 : 0)
        let next = min(max(idx + delta, 0), visible.count - 1)
        selection = visible[next].key
        return .handled
    }

    /// Vim-style `gg` (double-g within 400ms jumps to top) and `G`→last.
    /// Extracted so the giant onKeyPress switch type-checks promptly.
    private func plainKeyG(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.shift) {
            handle(.goLast)
        } else {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastG < 0.4 {
                handle(.goFirst)
                lastG = 0
            } else {
                lastG = now
            }
        }
        return .handled
    }

    private func openTerminalForSelection() {
        if let s = visible.first(where: { $0.key == selection }) {
            openSession(s)
        }
    }

    /// resume ターミナルを開く。同一セッションのターミナル窓が既に開いて
    /// いれば新規作成せず前面に出す (重複タブ防止)。
    private func openTerminalWindow(for s: AgentSession) {
        if let w = TerminalWindowState.shared.existingWindow(forSession: s.key) {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        openWindow(id: "terminal", value: s.key)
    }

    /// ライブattach も同じセッションキーで重複判定 (resume が開いていれば
    /// そちらを前面に出す)。
    private func openAttachWindow(for s: AgentSession) {
        if let w = TerminalWindowState.shared.existingWindow(forSession: s.key) {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        openWindow(id: "terminal", value: "attach:\(s.key)\n\(s.tmuxSession ?? "")")
    }

    /// Click / ⏎: open the session in the right-hand panel. Running and
    /// waiting sessions default to the terminal tab; finished/idle sessions
    /// have nothing live to show, so they default to the detail tab.
    private func openSession(_ s: AgentSession) {
        DebugLog.write("openSession(\(s.key))")
        focusBoard()
        selection = s.key
        selected = s
        panelTab = (s.state == .running || s.state == .waiting) ? .terminal : .detail
        panelCollapsed = false
        if panelTab == .terminal {
            mountTerminal(s)
        } else {
            terminalReady = false
            probeGeneration += 1
            focusBoard()
        }
    }

    /// Mount the panel terminal *immediately* instead of waiting on the tmux
    /// probe. If the scanner already knows a live tmux mirror we start
    /// attached; otherwise we mount `.resume` right away and upgrade to
    /// `.attach` the moment the (cheap, cached) probe finds a live session.
    /// The old "ターミナルを準備中…" spinner gate effectively disappears — a
    /// PTY is on screen instantly and only restarts when a live mirror exists.
    private func mountTerminal(_ s: AgentSession) {
        guard s.state == .running || s.state == .waiting else { return }
        probeGeneration += 1
        let generation = probeGeneration
        // Known live mirror (from the scan-backed Enricher) → attach at once.
        panelModes[s.key] = s.tmuxSession.map { TerminalMode.attach($0) } ?? .resume
        terminalReady = true
        probeLive(s, generation: generation)
    }

    /// Probe in the background and upgrade resume → attach when it lands.
    /// Runs cheaply: the probe is non-login and TTL-cached, so a fresh open
    /// usually doesn't even fork a shell (the Enricher already probed).
    private func probeLive(_ s: AgentSession, generation: Int) {
        guard s.state == .running || s.state == .waiting else { return }
        let cwd = s.cwd
        Task.detached(priority: .userInitiated) {
            let name = TmuxProbe.liveSession(cwd: cwd)
            await MainActor.run {
                guard self.probeGeneration == generation,
                      self.selected?.key == s.key,
                      !self.panelCollapsed,
                      self.panelTab == .terminal else { return }
                guard let name else { return }   // no live tmux → keep resume
                SessionStore.shared.applyEnrichment(key: s.key, prState: nil, prNumber: nil, tmux: name)
                // .attach(name) changes terminalInstanceID → the panel remounts
                // the PTY as a live mirror instead of the resume we started.
                if self.panelModes[s.key] != .attach(name) {
                    self.panelModes[s.key] = .attach(name)
                }
            }
        }
    }

    /// →/l/⌘⏎: detail tab of the right panel.
    private func openDetailForSelection() {
        if let s = visible.first(where: { $0.key == selection }) {
            openDetailTab(s)
        }
    }

    private func openDetailTab(_ s: AgentSession) {
        focusBoard()
        selection = s.key
        selected = s
        panelTab = .detail
        panelCollapsed = false
        terminalReady = false
        probeGeneration += 1
    }

    /// 引継 tab of the right panel (別エージェントへ引き継ぎ・引継書コピー).
    private func openHandoffTab(_ s: AgentSession) {
        focusBoard()
        selection = s.key
        selected = s
        panelTab = .handoff
        panelCollapsed = false
        terminalReady = false
        probeGeneration += 1
    }

    private func openHandoffTabForSelection() {
        if let s = visible.first(where: { $0.key == selection }) {
            openHandoffTab(s)
        }
    }

    private func openHandoffForSelection() {
        if let s = visible.first(where: { $0.key == selection }) {
            openWindow(id: "terminal", value: "handoff:\(s.key)")
        }
    }

    private func copyHandoffForSelection() {
        if let s = visible.first(where: { $0.key == selection }) {
            RepoTools.copyHandoff(s)
        }
    }

    private func openGitHubForSelection() {
        if let s = visible.first(where: { $0.key == selection }) {
            RepoTools.openPR(s)
        }
    }

    private func openFinderForSelection() {
        if let s = visible.first(where: { $0.key == selection }) {
            RepoTools.revealInFinder(s)
        }
    }

    /// Double-click / context menu: full separate terminal window.
    /// Click = live tmux attach when a mirror exists (real-time view+input
    /// from both terminals); otherwise --resume. When the scan-backed
    /// enrichment already knows a live tmux session we open instantly;
    /// otherwise the (cheap, cached) probe decides before the window opens.
    private func openTerminal(for s: AgentSession) {
        guard s.state == .running || s.state == .waiting else {
            openWindow(id: "terminal", value: s.key)
            return
        }
        if let name = s.tmuxSession {
            openWindow(id: "terminal", value: "attach:\(s.key)\n\(name)")
            return
        }
        let cwd = s.cwd
        Task.detached(priority: .userInitiated) {
            let name = TmuxProbe.liveSession(cwd: cwd)
            await MainActor.run {
                if let name {
                    SessionStore.shared.applyEnrichment(key: s.key, prState: nil, prNumber: nil, tmux: name)
                    openWindow(id: "terminal", value: "attach:\(s.key)\n\(name)")
                } else {
                    openWindow(id: "terminal", value: s.key)
                }
            }
        }
    }

    // MARK: right panel show/hide & resize

    /// Hide the panel and dismantle its embedded terminal. The next explicit
    /// show/open action will probe and mount it again once.
    private func collapsePanel() {
        guard selected != nil else { return }
        panelCollapsed = true
        terminalReady = false
        probeGeneration += 1
        // Lift keyboard out of the (now invisible) terminal and hand it to
        // the board — never to the search field, which SwiftUI would pick
        // as the first focusable control if we nilled the responder.
        focusBoard()
    }

    private func togglePanel() {
        if selected == nil {
            if let s = visible.first { openSession(s) }
            return
        }
        if panelCollapsed {
            panelCollapsed = false
            if panelTab == .terminal, let s = selected {
                mountTerminal(s)
            } else {
                focusBoard()
            }
        } else {
            collapsePanel()
        }
    }

    /// Board keys become live again and the search field is explicitly
    /// released — the only way search focus is granted is ⌘F.
    private func focusBoard() {
        DebugLog.write("focusBoard()")
        searchFocused = false
        sidebarFocused = false
        region = .board
        boardFocused = true
        syncKeyGate()
    }

    /// Finder-style: bare printable keys accumulate a prefix filter that
    /// narrows the session list, then clear themselves after 2s of silence.
    private func appendTypeAhead(_ s: String) {
        typeAheadGen += 1
        let gen = typeAheadGen
        typeAhead += s
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard gen == typeAheadGen else { return }
            typeAhead = ""
        }
        if let top = visible.first { selection = top.key }
    }

    /// Focus the embedded terminal once it's in the view tree, and release
    /// the board's SwiftUI focus at that moment — otherwise the hosting view
    /// re-asserts itself and the shell's keystrokes land in the middle panel.
    private func scheduleTerminalFocus() {
        DeckFocus.terminal { [self] in
            self.boardFocused = false
        }
    }

    // MARK: bare terminals & project management

    /// Plain zsh terminal window in a folder (⌘T / サイドバー+).
    private func openBareTerminal(_ cwd: String?) {
        let dir = SafeCwd.resolve(cwd) ?? FileManager.default.homeDirectoryForCurrentUser.path
        openWindow(id: "terminal", value: "bare:\(dir)")
    }

    private func openBareTerminalPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "ここにターミナルを開く"
        if panel.runModal() == .OK, let url = panel.url {
            openWindow(id: "terminal", value: "bare:\(url.path)")
        }
    }

    private func addProjectFlow() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "プロジェクトに追加"
        if panel.runModal() == .OK, let url = panel.url {
            ProjectStore.shared.add(name: url.lastPathComponent, path: url.path)
            sidebar = .project(url.lastPathComponent)
        }
    }

    private func cwd(forProject p: String) -> String? {
        if let m = ProjectStore.shared.manual.first(where: { $0.name == p }) { return m.path }
        return store.sessions.first(where: { $0.project == p })?.cwd
    }

    // MARK: ⌘K palette catalog

    private func paletteCatalog() -> [PaletteItem] {
        var items: [PaletteItem] = [
            PaletteItem(title: "右パネルで開く", subtitle: "実行中・入力待ち=ターミナル / 完了・失敗=詳細 (⏎)", icon: "terminal", tint: .blue, action: { self.openTerminalForSelection() }),
            PaletteItem(title: "詳細を開く", subtitle: "選択中セッションの詳細タブ (→)", icon: "doc.text.magnifyingglass", tint: .teal, action: { self.openDetailForSelection() }),
            PaletteItem(title: "別エージェントへ引き継ぐ", subtitle: "引継書 + エージェント選択（右パネル）", icon: "arrow.triangle.swap", tint: .orange, action: { self.openHandoffTabForSelection() }),
            PaletteItem(title: "引継書をコピー", subtitle: "選択中セッション", icon: "doc.on.doc", action: { self.copyHandoffForSelection() }),
            PaletteItem(title: "GitHubで開く", subtitle: "選択中セッションのPR/リポジトリ", icon: "globe", action: { self.openGitHubForSelection() }),
            PaletteItem(title: "Finderで開く", subtitle: "選択中セッションの作業フォルダ", icon: "folder", action: { self.openFinderForSelection() }),
            PaletteItem(title: "新規ターミナル", subtitle: "ホームディレクトリで zsh (⌘T)", icon: "terminal.fill", action: { self.openBareTerminal(nil) }),
            PaletteItem(title: "右パネル表示切替", subtitle: "ターミナルを生かしたまま隠す/出す (←/h)", icon: "sidebar.right", action: { self.togglePanel() }),
            PaletteItem(title: "ハンドオフ（同一エージェント）", subtitle: "要約を渡した新規セッション (⌘⇧N)", icon: "arrow.forward.square", tint: .orange, action: { self.openHandoffForSelection() }),
            PaletteItem(title: "再スキャン", subtitle: "transcriptを再読込 (⌘R)", icon: "arrow.clockwise", tint: .green, action: { TranscriptScanner.shared.rescan() }),
            PaletteItem(title: "履歴表示を切替", subtitle: "昨日より前のセッションも表示 (⌘⇧H)", icon: "clock.arrow.circlepath", action: { self.store.showHistory.toggle() }),
            PaletteItem(title: "リネーム", subtitle: "選択中セッション (r)", icon: "pencil", action: { self.startRename(self.selection ?? self.visible.first?.key) }),
            PaletteItem(title: "すべて表示", subtitle: "サイドバー (1)", icon: "square.grid.2x2", action: { self.sidebar = .all }),
            PaletteItem(title: "アーカイブ", subtitle: "サイドバー (2)", icon: "archivebox", action: { self.sidebar = .archive }),
            PaletteItem(
                title: "アクティブのみ表示",
                subtitle: "入力待ち+実行中+失敗（サイドバー: 3）",
                icon: "bolt.horizontal.circle",
                tint: .blue,
                action: { self.sidebar = .active }
            ),
        ]
        let stateItems: [(SessionState, String, Color, String)] = [
            (.waiting, "hand.raised", .yellow, ""),
            (.running, "play.circle", .blue, ""),
            (.failed, "exclamationmark.triangle", .red, "6"),
            (.done, "checkmark.circle", .green, "4"),
            (.idle, "moon.zzz", .gray, "5"),
        ]
        for (state, icon, tint, key) in stateItems {
            items.append(PaletteItem(
                title: "\(state.label) のみ表示",
                subtitle: key.isEmpty ? "サイドバー" : "サイドバー (\(key))",
                icon: icon,
                tint: tint,
                action: { self.sidebar = .state(state) }
            ))
        }
        for a in agents {
            items.append(PaletteItem(
                title: a.0,
                subtitle: "エージェント (\(a.1)) — 絞り込み (a で切替)",
                icon: "terminal",
                action: { self.sidebar = .agent(a.0) }
            ))
        }
        for p in projects {
            items.append(PaletteItem(
                title: p.0,
                subtitle: "プロジェクト (\(p.1)) — 絞り込み (p で切替)",
                icon: "folder",
                action: { self.sidebar = .project(p.0) }
            ))
        }
        for s in baseSessions.prefix(15) {
            var sub = s.repoName
            if let b = s.branch { sub += " ⎇ \(b)" }
            if let n = s.prNumber, let st = s.prState, st != "none" { sub += " · PR #\(n) \(st.lowercased())" }
            sub += " · \(s.agent)"
            items.append(PaletteItem(
                title: s.title,
                subtitle: sub,
                icon: "square.stack.3d.up",
                tint: s.state.color,
                action: { self.openSession(s) }
            ))
        }
        return items
    }

    // MARK: rename

    private func startRename(_ key: String?) {
        guard let key, let s = visible.first(where: { $0.key == key }) else { return }
        selection = key
        renamingKey = key
        renameDraft = s.title
    }

    private func commitRename() {
        defer { renamingKey = nil }
        let t = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = renamingKey, !t.isEmpty else { return }
        store.rename(key: key, t)
    }

    private func syncKeyGate() {
        KeyGate.suppressBoardKeys = searchFocused || sidebarFocused || renamingKey != nil
    }

    /// Detail tab visible → board nav keys must not fire behind the panel.
    private func syncPanelGate() {
        KeyGate.detailPanelActive = panelTab == .detail && !panelCollapsed
    }

    // MARK: archive

    private var archiveDays: [(String, [AgentSession])] {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let list = query.isEmpty ? archivedSessions : archivedSessions.filter { $0.matches(query) }
        return Dictionary(grouping: list) { fmt.string(from: $0.lastActivity) }
            .sorted { $0.key > $1.key }
            .map { ($0.key, $0.value.sorted { $0.lastActivity > $1.lastActivity }) }
    }

    private var archiveList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if archiveDays.isEmpty {
                    Text("アーカイブはまだありません（4時間以上入力がないセッションがここに移動）")
                        .font(.caption).foregroundStyle(.secondary).padding(14)
                }
                ForEach(archiveDays, id: \.0) { day, sessions in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(day).font(.headline)
                            Text("\(sessions.count)件")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                        if let digest = digestText(for: day) {
                            DisclosureGroup("ダイジェスト") {
                                MarkdownView(text: digest)
                                    .font(.caption)
                                    .padding(6)
                            }
                        }
                        ForEach(sessions) { s in
                            ArchiveRow(session: s, isSelected: s.key == selection)
                                .contextMenu { archiveCardMenu(s) }
                                .onTapGesture {
                                    selection = s.key
                                    focusBoard()
                                }
                        }
                    }
                }
            }
            .padding(10)
        }
        .workspaceOpenURL()
    }

    @ViewBuilder
    private func archiveCardMenu(_ session: AgentSession) -> some View {
        Button("アーカイブから戻す") { unarchiveSession(session) }
        Divider()
        Button("右パネルで開く") { openSession(session) }
        Button("リネーム") { startRename(session.key) }
        Button("AIでタイトル生成…") { aiRenameTarget = session }
        Button("引継書をコピー") { RepoTools.copyHandoff(session) }
        Button("Finderで開く") { RepoTools.revealInFinder(session) }
    }

    private func archiveSession(_ session: AgentSession) {
        store.archive(session.key)
        if selected?.key == session.key {
            selected = nil
            panelCollapsed = true
            terminalReady = false
            probeGeneration += 1
        }
        if selection == session.key { selection = nil }
    }

    private func unarchiveSession(_ session: AgentSession) {
        store.unarchive(session.key)
        selection = session.key
    }

    private func digestText(for day: String) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("dev/agentdeck/vault/\(day).md")
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// Archive entry: the card plus the session's final exchange underneath,
/// so a day-old session is recallable at a glance without opening it.
struct ArchiveRow: View {
    let session: AgentSession
    var isSelected = false
    @State private var lastUser: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SessionCard(session: session, isSelected: isSelected)
            if let lastUser {
                Text("You: " + SessionCard.oneLine(lastUser))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
        }
        .onAppear {
            guard lastUser == nil, let path = session.transcriptPath else { return }
            lastUser = TranscriptReader.turns(path: path, limit: 10)
                .last(where: { $0.role == "user" })?.text
        }
    }
}

struct SidebarRow: View {
    let label: String
    var systemImage: String? = nil
    var color: Color? = nil
    let count: Int
    var emphasized = false
    @ObservedObject private var ui = UISettings.shared

    var body: some View {
        HStack {
            if let color {
                Circle().fill(color).frame(width: 8, height: 8)
            } else if let systemImage {
                Image(systemName: systemImage).foregroundStyle(.secondary)
            }
            Text(label)
                .lineLimit(1)
                .font(ui.customFont(size: ui.sidebarSize, weight: emphasized ? .semibold : .regular))
            Spacer()
            Text("\(count)")
                .font(ui.customFont(size: ui.sidebarSize - 2, weight: emphasized ? .semibold : .regular))
                .foregroundStyle(emphasized ? .primary : .secondary)
        }
    }
}

struct SessionCard: View {
    let session: AgentSession
    var isSelected = false
    /// 親カードに内包されたサブエージェント数 (リスト Item には出さず、
    /// カード内チップで内包数を示すだけ)。
    var subagentCount = 0
    var isRenaming = false
    var renameText: Binding<String>? = nil
    var onRenameCommit: () -> Void = {}
    var onRenameCancel: () -> Void = {}
    @ObservedObject private var ui = UISettings.shared
    @State private var heightDragStart: Double?
    /// Card-level FM summary (shared cache with the detail panel 履歴 tab).
    /// Loaded / queued on appear; invalidated when the session updates.
    @State private var cardSummary: String?
    @State private var summaryMtime: Date?
    /// Trello card link mentioned anywhere in the session text.
    @State private var trello: URL?

    static func oneLine(_ s: String) -> String {
        let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ")
        return String(flat.prefix(120))
    }

    static func duration(_ s: AgentSession) -> String? {
        guard let st = s.startedAt else { return nil }
        let d = s.lastActivity.timeIntervalSince(st)
        guard d > 5 else { return nil }
        let m = Int(d) / 60
        let h = m / 60
        if h > 0 { return "\(h)h\(m % 60)m" }
        if m > 0 { return "\(m)m" }
        return "\(Int(d))s"
    }

    /// First two lines of the FM summary, flattened for a card preview.
    static func summaryLine(_ s: String) -> String {
        let lines = s.split(whereSeparator: \.isNewline).map(String.init)
        let headline = lines.first { $0.hasPrefix("結論") || $0.hasPrefix("結論") } ?? lines.first ?? ""
        let flat = lines.prefix(2).joined(separator: " ")
        let chosen = flat.isEmpty ? headline : flat
        return String(chosen.prefix(160))
    }

    private static let trelloPattern = try? NSRegularExpression(
        pattern: "https?://(?:www\\.)?trello\\.com/c/[A-Za-z0-9]+")

    static func trelloURL(for s: AgentSession) -> URL? {
        for field in [s.title, s.firstPrompt ?? "", s.lastAssistant ?? ""] where !field.isEmpty {
            let ns = field as NSString
            for m in Self.trelloPattern?.matches(in: field, range: NSRange(location: 0, length: ns.length)) ?? [] {
                return URL(string: ns.substring(with: m.range))
            }
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(session.state.color)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                if isRenaming, let renameText {
                    RenameField(
                        text: renameText,
                        fontFamily: ui.fontFamily,
                        fontSize: ui.effectiveBoardSize,
                        onCommit: onRenameCommit,
                        onCancel: onRenameCancel
                    )
                } else {
                    Text(session.title)
                        .font(ui.customFont(size: ui.effectiveBoardSize, weight: .medium))
                        .lineLimit(1)
                }
                if let last = session.lastAssistant {
                    HStack(spacing: 4) {
                        Text("→")
                            .font(ui.customFont(size: ui.effectiveBoardSize - 4, weight: .bold))
                            .foregroundStyle(session.state.color)
                        Text(Self.oneLine(last))
                            .font(ui.customFont(size: ui.effectiveBoardSize - 4))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                // FM要約 (要約タブとキャッシュ共有)。あれば最新状況を一読で掴める。
                if let cardSummary, !cardSummary.isEmpty {
                    Text(Self.summaryLine(cardSummary))
                        .font(ui.customFont(size: ui.effectiveBoardSize - 4))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ViewThatFits(in: .horizontal) {
                    metaRow(full: true)
                    metaRow(full: false)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 6) {
                    if subagentCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.turn.down.right")
                            Text("\(subagentCount)")
                        }
                        .font(ui.customFont(size: ui.effectiveBoardSize - 5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.13), in: RoundedRectangle(cornerRadius: 5))
                        .help("サブエージェント \(subagentCount) 件をこのカードに内包")
                    }
                    if let trello {
                        Button {
                            NSWorkspace.shared.open(trello)
                        } label: {
                            Image(systemName: "list.clipboard")
                                .font(ui.customFont(size: ui.effectiveBoardSize - 3))
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                        .help("Trelloカードを開く")
                    }
                    if session.prState != nil && session.prState != "none" || session.branch != nil {
                        Button {
                            RepoTools.openPR(session)
                        } label: {
                            Image(systemName: "globe")
                                .font(ui.customFont(size: ui.effectiveBoardSize - 3))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("GitHub PR/リポジトリを開く")
                    }
                }
                Text(session.state.label)
                    .font(ui.customFont(size: ui.effectiveBoardSize - 3, weight: .semibold))
                    .foregroundStyle(session.state.color)
                Text(SessionStore.relativeAge(session.lastActivity))
                    .font(ui.customFont(size: ui.effectiveBoardSize - 4))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(minHeight: ui.effectiveCardHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(session.state.color.opacity(isSelected ? 0.14 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isSelected ? Color.accentColor : session.state.color.opacity(0.25),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .overlay(alignment: .bottom) { heightGrip }
        .onAppear { loadCardSummary() }
        .onChange(of: session.lastActivity) { _, _ in loadCardSummary() }
        .padding(.leading, 0)
    }

    private func loadCardSummary() {
        trello = Self.trelloURL(for: session)
        let m = session.lastActivity
        guard summaryMtime != m else { return }
        summaryMtime = m
        if let cached = SummaryCache.get(session.key, mtime: m) {
            cardSummary = cached
        } else {
            cardSummary = nil
            guard let path = session.transcriptPath,
                  session.lastAssistant != nil || session.firstPrompt != nil else { return }
            CardSummarizer.shared.ensure(key: session.key, path: path, mtime: m) { text, mtime in
                guard session.key == self.session.key, self.summaryMtime == mtime else { return }
                self.cardSummary = text
            }
        }
    }

    /// Invisible bottom-edge strip that drags the persisted card height.
    private var heightGrip: some View {
        Rectangle()
            .fill(.clear)
            .frame(height: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        if heightDragStart == nil { heightDragStart = ui.cardHeight }
                        ui.cardHeight = min(max(heightDragStart! + v.translation.height, 44), 160)
                    }
                    .onEnded { _ in heightDragStart = nil }
            )
            .help("カードの高さを調整")
    }

    /// Location first (repo/folder → branch → PR), then agent, then badges —
    /// the order that answers "どのレポのどのフォルダのどのPR".
    private func metaRow(full: Bool) -> some View {
        HStack(spacing: 6) {
            Label(session.repoName, systemImage: "folder")
                .font(ui.customFont(size: ui.effectiveBoardSize - 3))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(session.cwd ?? session.project)
            if full, let branch = session.branch {
                Text("⎇ \(branch)")
                    .font(ui.customFont(size: ui.effectiveBoardSize - 4))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("gitブランチ")
            }
            if full, let pr = session.prState, pr != "none" {
                let label = pr == "MERGED" ? "merged" : pr == "OPEN" ? "open" : "closed"
                let color: Color = pr == "MERGED" ? .green : pr == "OPEN" ? .yellow : .red
                Text("PR #\(session.prNumber.map { String($0) } ?? "?") \(label)")
                    .font(ui.customFont(size: ui.effectiveBoardSize - 4, weight: .semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(color.opacity(0.15)))
                    .help("GitHub Pull Request")
            }
            Text(session.agent)
                .font(ui.customFont(size: ui.effectiveBoardSize - 3))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if full, session.hasWorktree {
                Text("wt")
                    .font(ui.customFont(size: ui.effectiveBoardSize - 4, weight: .semibold))
                    .foregroundStyle(.purple)
            }
            if full, session.tmuxSession != nil {
                Text("tmux")
                    .font(ui.customFont(size: ui.effectiveBoardSize - 4, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .help("qwen-tmuxのライブセッションあり — clickでミラーattach")
            }
            if full, let d = Self.duration(session) {
                Text(d)
                    .font(ui.customFont(size: ui.effectiveBoardSize - 4))
                    .foregroundStyle(.tertiary)
            }
            Text("#" + session.shortID)
                .font(ui.customFont(size: ui.effectiveBoardSize - 4))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.white.opacity(0.07)))
                .onTapGesture {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.sessionId, forType: .string)
                }
                .help("クリックでセッションIDをコピー: \(session.sessionId)")
        }
    }
}

/// AppKit-backed single-line rename field. SwiftUI TextField + FocusState can
/// leave the window without an editing responder (IME composition then goes
/// nowhere), so this field grabs the AppKit first responder itself on appear
/// and keeps the field editor alive — the Japanese input method works here.
struct RenameField: NSViewRepresentable {
    @Binding var text: String
    var fontFamily: String
    var fontSize: Double
    var onCommit: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField(string: text)
        f.isBordered = false
        f.isBezeled = false
        f.drawsBackground = false
        f.usesSingleLineMode = true
        f.focusRingType = .none
        f.font = Self.makeFont(fontFamily: fontFamily, size: fontSize)
        f.delegate = context.coordinator
        context.coordinator.parent = self
        DispatchQueue.main.async {
            guard let win = f.window else { return }
            win.makeFirstResponder(f)
            f.currentEditor()?.selectAll(nil)
        }
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func makeFont(fontFamily: String, size: Double) -> NSFont {
        if fontFamily.isEmpty { return .systemFont(ofSize: size, weight: .medium) }
        return NSFont(name: fontFamily, size: size) ?? .systemFont(ofSize: size, weight: .medium)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RenameField
        init(_ p: RenameField) { parent = p }

        func controlTextDidEndEditing(_ obj: Notification) {
            if let f = obj.object as? NSTextField { parent.text = f.stringValue }
            parent.onCommit()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)):
                parent.text = (control as? NSTextField)?.stringValue ?? parent.text
                parent.onCancel()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.text = (control as? NSTextField)?.stringValue ?? parent.text
                parent.onCommit()
                return true
            default:
                return false
            }
        }
    }
}
