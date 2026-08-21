import SwiftUI
import AppKit
import SwiftTerm

@main
struct AgentDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("AgentDeck") {
            BoardView()
                .frame(minWidth: 420, minHeight: 320)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            DashboardCommands()
            CommandMenu("セッション") {
                // No Return/⌘⏎ key equivalents here: menu equivalents fire even
                // while the search field is editing, opening terminals behind the
                // user's back. The board window's NSEvent monitor owns those keys.
                Button("コマンドパレット") { HotkeyRouter.shared.fire(.palette) }
                    .keyboardShortcut("k", modifiers: .command)
                Button("新規ターミナル") { HotkeyRouter.shared.fire(.newTerminal) }
                    .keyboardShortcut("t", modifiers: .command)
                Button("ターミナルを開く") { HotkeyRouter.shared.fire(.openTerminal) }
                Button("閉じたターミナルを開き直す") { HotkeyRouter.shared.fire(.reopenLastTerminal) }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("詳細を開く") { HotkeyRouter.shared.fire(.openDetail) }
                Button("新規セッションへハンドオフ") { HotkeyRouter.shared.fire(.handoff) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("transcript再スキャン") { HotkeyRouter.shared.fire(.rescan) }
                    .keyboardShortcut("r", modifiers: .command)
                Button("履歴表示切替") { HotkeyRouter.shared.fire(.toggleHistory) }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("セッション検索") { HotkeyRouter.shared.fire(.search) }
                    .keyboardShortcut("f", modifiers: .command)
            }
        }
        // one window per resumed/handed-off session — open as many as needed
        WindowGroup(id: "terminal", for: String.self) { spec in
            TerminalWindowRoot(spec: spec.wrappedValue ?? "")
        }
        .defaultSize(width: 1000, height: 640)

        WindowGroup(id: "detail", for: String.self) { key in
            DetailWindowRoot(key: key.wrappedValue ?? "")
        }
        .defaultSize(width: 620, height: 520)

        WindowGroup(id: "dashboard") {
            DashboardView()
                .frame(minWidth: 760, minHeight: 560)
        }
        .defaultSize(width: 1020, height: 760)

        Settings {
            SettingsView()
        }
    }
}

/// ダッシュボードを開くメニュー (⌘D)。openWindow は Commands の
/// Environment からしか取れないので専用 struct にする。
private struct DashboardCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("表示") {
            Button("ダッシュボード") { openWindow(id: "dashboard") }
                .keyboardShortcut("d", modifiers: .command)
        }
    }
}

struct DetailWindowRoot: View {
    let key: String
    @ObservedObject private var store = SessionStore.shared
    @ObservedObject private var router = HotkeyRouter.shared

    var body: some View {
        Group {
            if let session = store.sessions.first(where: { $0.key == key }) {
                SessionDetailView(session: session, onClose: { })
                    .frame(minWidth: 580, minHeight: 460)
            } else {
                Text("セッションが見つかりません: \(key)")
                    .foregroundStyle(.secondary)
                    .onAppear {
                        ErrorCenter.shared.post("セッションが見つかりません", detail: key)
                    }
            }
        }
        .overlay(alignment: .top) { ErrorBanner() }
        .overlay(alignment: .topTrailing) {
            ErrorDot().padding(.top, 14).padding(.trailing, 20)
        }
        // ⌘K グローバルパレット — ボード以外の窓からも開ける。
        .overlay {
            if router.paletteOpen {
                PaletteView(items: GlobalPaletteCatalog.items())
                    .padding(.top, 48)
            }
        }
    }
}

struct TerminalWindowRoot: View {
    let spec: String
    @ObservedObject private var store = SessionStore.shared
    @ObservedObject private var ui = UISettings.shared
    @ObservedObject private var router = HotkeyRouter.shared
    // クリック不要でそのまま入力できるよう、このウィンドウがキー窓になった
    // タイミングでターミナルビューを自動フォーカスする。
    @State private var nsWindow: NSWindow?
    /// bare ターミナルの cwd 追跡タイトル (nil なら通常のメタタイトル)。
    @State private var liveCwdTitle: String?

    private var key: String {
        var s = spec
        // "handoffto:<agent>\n<key>" — the key lives on the second line.
        if s.hasPrefix("handoffto:"), let nl = s.firstIndex(of: "\n") {
            s = String(s[s.index(after: nl)...])
        }
        for prefix in ["handoff:", "comment:", "attach:"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        if let nl = s.firstIndex(of: "\n") {
            s = String(s[..<nl])
        }
        return s
    }

    private var mode: TerminalMode {
        if spec.hasPrefix("handoffto:"), let nl = spec.firstIndex(of: "\n") {
            let target = String(spec[spec.index(spec.startIndex, offsetBy: 10)..<nl])
            return .handoffTo(target)
        }
        if spec.hasPrefix("handoff:") { return .handoff }
        if spec.hasPrefix("comment:"), let nl = spec.firstIndex(of: "\n") {
            return .comment(String(spec[spec.index(after: nl)...]))
        }
        if spec.hasPrefix("attach:"), let nl = spec.firstIndex(of: "\n") {
            return .attach(String(spec[spec.index(after: nl)...]))
        }
        if spec.hasPrefix("bare:") {
            return .bare(String(spec.dropFirst(5)))
        }
        return .resume
    }

    /// A bare-terminal spec has no stored session — synthesize an ephemeral
    /// one so the whole pipeline (header, terminal, fonts) works unchanged.
    private var session: AgentSession? {
        if let s = store.sessions.first(where: { $0.key == key }) { return s }
        guard case .bare(let cwd) = mode else { return nil }
        let name = (cwd as NSString).lastPathComponent
        return AgentSession(
            key: "bare:\(cwd)",
            agent: "zsh",
            project: name,
            title: "新規ターミナル — \(name)",
            state: .running,
            lastActivity: Date(),
            lastEvent: "new",
            cwd: cwd
        )
    }

    var body: some View {
        Group {
            if let session {
                TerminalSheetView(session: session, mode: mode, onLiveTitle: { liveCwdTitle = $0 })
                    .navigationTitle(liveCwdTitle ?? windowTitle(for: session))
            } else {
                Text("セッションが見つかりません: \(key)")
                    .foregroundStyle(.secondary)
                    .onAppear {
                        ErrorCenter.shared.post("セッションが見つかりません", detail: "spec: \(spec)")
                    }
            }
        }
        .overlay(alignment: .top) { ErrorBanner() }
        .overlay(alignment: .topTrailing) {
            ErrorDot().padding(.top, 14).padding(.trailing, 20)
        }
        // ⌘K グローバルパレット — ボード以外の窓からも開ける。
        .overlay {
            if router.paletteOpen {
                PaletteView(items: GlobalPaletteCatalog.items())
                    .padding(.top, 48)
            }
        }
        .windowTransparency(ui.terminalOpacity)
        // Track this window in the restore registry (spec + windowNumber).
        .background(WindowAccessor { w in
            if let w {
                let firstCapture = nsWindow == nil
                nsWindow = w
                if firstCapture, w.isKeyWindow {
                    // 開いた直後: didBecomeKey 通知が nsWindow 取得より先に
                    // 飛ぶことがあるため、こちらでも初回フォーカスを入れる。
                    DeckFocus.terminal()
                }
                TerminalWindowState.shared.register(spec: spec, windowNumber: w.windowNumber)
            }
        })
        // キー窓になるたび (開いた瞬間・別窓から戻ってきた瞬間) にターミナルへ
        // 自動フォーカス — いちいちクリックしなくてもそのまま入力できる。
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let w = note.object as? NSWindow, w === nsWindow else { return }
            DeckFocus.terminal()
        }
        .onDisappear {
            // Works regardless of which window closed: TerminalWindowRoot
            // instances share the same spec (multi-window resume), so the
            // registry needs no window context here — unregister(_, windowNumber:)
            // would drop the wrong one. Instead, drop all entries whose window
            // is gone, handled by saveNow() on the next quit; removing this
            // spec's dead windows now keeps the saved set correct live.
            TerminalWindowState.shared.unregister(spec: spec)
        }
    }

    /// The window/tab title carries the same meta the board card shows:
    /// colored state dot, project, session title, branch and PR — so merged
    /// tabs and the ⌘⇧` switcher are tellable apart at a glance.
    private func windowTitle(for s: AgentSession) -> String {
        var t = "\(s.state.dot) \(s.project) / \(s.title)"
        if let b = s.branch { t += " ⎇ \(b)" }
        if let pr = s.prNumber {
            t += " · PR #\(pr)\(s.prState == "MERGED" ? " merged" : "")"
        }
        t += " · \(s.agent)"
        return t
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let server = EventServer()
    /// MCP (Model Context Protocol) server for Cursor/Claude Desktop/opencode
    /// — status, summaries, resume session ids and vault reminders.
    private let mcp = MCPServer()
    /// Timestamp of the last bare "g" key (vim-style gg = jump to top).
    private var lastG: Double = 0
    /// Timestamp of the last ⌘ key-down (⌘⌘ double-tap toggles dictation).
    private var lastCmdTap: Double = 0
    /// Terminal that held keyboard focus when ⌘K opened the palette; closing
    /// the palette hands focus back to it instead of the board.
    private weak var paletteTerminalView: LocalProcessTerminalView?
    /// Trackpad-swipe accumulator (board window only): a two-finger swipe
    /// left/right toggles the right panel, Safari-style. Sign: with natural
    /// scrolling, fingers moving LEFT give a positive scrollingDeltaX.
    private var swipeDX: CGFloat = 0
    private var swipeDY: CGFloat = 0
    /// 二重起動で自分が「お役御免」として終了するとき true。この場合は
    /// ターミナル窓リストを保存してはいけない (既存インスタンスの状態が
    /// 空で上書きされるのを防ぐ)。
    private var isDuplicateTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // シングルインスタンス: 既に起動中の AgentDeck があれば、そちらを
        // 前面に出して自分は何もせず終了する。二重起動で同じセッションの
        // ターミナル窓と opencode2 プロセスが 2 セット並ぶのを防ぐ。
        let pid = ProcessInfo.processInfo.processIdentifier
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.agentdeck.app")
            .first(where: { $0.processIdentifier != pid }) {
            isDuplicateTermination = true
            existing.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        server.start()
        mcp.start()
        Notifier.installDelegate()
        TranscriptScanner.shared.start()
        installKeyMonitor()
        installSwipeMonitor()
        loadAppIcon()
        reapOrphanOpencode2()
        // Reopen the saved terminal window set. The board view owns the
        // openWindow environment and subscribes to HotkeyRouter on appear, so
        // wait one beat before replaying specs; missing sessions are retried
        // inside restoreAfterLaunch while the startup scan fills the store.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated {
                TerminalWindowState.shared.restoreAfterLaunch()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 二重起動で自分が終了するときは窓リストを保存しない
        // (既存インスタンスの状態を空で上書きしないため)。
        guard !isDuplicateTermination else { return }
        // Persist which tabs are open (in screen order) for the next launch.
        MainActor.assumeIsolated {
            TerminalWindowState.shared.saveNow()
        }
    }

    /// 前回のクラッシュ/強制終了 (pkill 等) で置き去りにされた orphan の
    /// opencode2 --auto プロセスを掃除する。対象は「親プロセスが死んで
    /// いる (PPID が存在しない)」ものだけ。UI から起動されたターミナルは
    /// 自分 (AgentDeck) が親なので対象外。ユーザーが別途起動した
    /// opencode2 は `--session` 単体 (--auto なし) なので対象外。
    private func reapOrphanOpencode2() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", """
            for p in $(pgrep -f 'opencode2 --auto --session '); do
                ppid=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
                if [[ -z "$ppid" ]] || ! kill -0 "$ppid" 2>/dev/null; then
                    kill "$p" 2>/dev/null
                fi
            done
            """]
        try? task.run()
    }

    /// Trackpad swipe = show/hide the right panel without touching keys the
    /// shell owns. Scroll events with a horizontal-dominant, fast-enough
    /// swipe toggle the panel; plain vertical scrolling (session list) and
    /// wheel scrolling inside the embedded terminal pass through untouched.
    private func installSwipeMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] ev in
            guard let self, let win = ev.window else { return ev }
            guard win.title == "AgentDeck" || win.title.isEmpty else { return ev }
            guard !HotkeyRouter.shared.paletteOpen else { return ev }
            // The embedded terminal owns its scrollback — never hijack wheel
            // events that land on it (hit-testing covers the whole panel).
            let p = win.contentView?.convert(ev.locationInWindow, from: nil) ?? .zero
            if let hit = win.contentView?.hitTest(p) {
                var node: NSView? = hit
                while let v = node {
                    if v is LocalProcessTerminalView { return ev }
                    node = v.superview
                }
            }
            let phase = ev.phase
            let momentum = ev.momentumPhase
            if phase.contains(.began) || momentum.contains(.began) {
                self.swipeDX = 0
                self.swipeDY = 0
            }
            self.swipeDX += ev.scrollingDeltaX
            self.swipeDY += ev.scrollingDeltaY
            if phase.contains(.ended) || momentum.contains(.ended) {
                let dx = self.swipeDX, dy = self.swipeDY
                self.swipeDX = 0
                self.swipeDY = 0
                // Vertical list scrolls dominate on dy; only a real horizontal
                // swipe (60pt+, 1.5× the vertical drift) toggles the panel.
                guard abs(dx) > 60, abs(dx) > abs(dy) * 1.5 else { return ev }
                if dx > 0 { HotkeyRouter.shared.fire(.panelHide) }
                else { HotkeyRouter.shared.fire(.panelShow) }
            }
            return ev
        }
    }

    /// "1"…"9" → 0…8 (nil for anything else).
    private static func tabDigit(_ chars: String) -> Int? {
        guard chars.count == 1, let c = chars.first, c.isNumber,
              let i = c.wholeNumberValue, (1...9).contains(i) else { return nil }
        return i - 1
    }

    /// ⌘1…9 target: the digit-th item of the window's tab group when system
    /// tabbing is active; otherwise the digit-th visible standalone window in
    /// screen order (left→right, top→bottom — same order saveNow persists).
    private static func tabTarget(digit: Int, from win: NSWindow) -> NSWindow? {
        let tabs = win.tabbedWindows ?? []
        if tabs.count > 1 {
            return digit < tabs.count ? tabs[digit] : nil
        }
        let others = NSApp.windows
            .filter { $0.isVisible && !($0.title.isEmpty || $0.title == "AgentDeck") }
            .sorted { a, b in
                if a.frame.minY != b.frame.minY { return a.frame.minY > b.frame.minY }
                return a.frame.minX < b.frame.minX
            }
        return digit < others.count ? others[digit] : nil
    }

    private func loadAppIcon() {
        // Bundle .icns (AgentDeck.app/Contents/Resources/AgentDeck.icns) first,
        // fall back to a baked-in NSImage for development builds.
        if let path = Bundle.main.path(forResource: "AgentDeck", ofType: "icns") {
            NSApp.applicationIconImage = NSImage(contentsOfFile: path)
        }
    }

    /// Close the palette and put keyboard focus back where it was before ⌘K
    /// (an embedded terminal, when the user was typing into one).
    private func closePaletteRestoringFocus() {
        defer { paletteTerminalView = nil }
        HotkeyRouter.shared.paletteClose()
        restorePaletteFocus()
    }

    /// Run the palette's selection, then restore focus like a plain close.
    private func runPaletteRestoringFocus() {
        HotkeyRouter.shared.paletteRun()
        restorePaletteFocus()
        paletteTerminalView = nil
    }

    private func restorePaletteFocus() {
        guard let t = paletteTerminalView, t.window != nil else { return }
        t.window?.makeFirstResponder(t)
    }

    /// AppKit-level key handling: SwiftUI focus is unreliable in split views,
    /// so the board window gets deterministic keys here. Text fields, terminals
    /// and other windows are never intercepted.
    private func installKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self else { return ev }
            let fr = ev.window?.firstResponder
            let flags = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Shift makes charactersIgnoringModifiers uppercase; normalize so
            // ⇧A/H/N match their lowercase cases.
            let chars = (ev.charactersIgnoringModifiers ?? "").lowercased()
            let router = HotkeyRouter.shared
#if DEBUG
            let frType = fr.map { String(describing: type(of: $0)) } ?? "nil"
            DebugLog.write("key keyCode=\(ev.keyCode) chars='\(chars)' flags=\(flags.rawValue) fr=\(frType) win='\(ev.window?.title ?? "")'")
#endif
            // ⌃⇧J / ⌃⇧L (ATOK IME toggle) must reach the input method before
            // SwiftTerm converts them into a control byte (⌃J = LF, ⌃L = FF).
            // Route only these exact combos through interpretKeyEvents; plain
            // ⌃J / ⌃L keep SwiftTerm's native control-byte behavior. Keys are
            // matched by keyCode (J=38, L=37): かな入力モードでは characters
            // が仮名や全角になり "j"/"l" に一致せず素通りしてしまうため、
            // 物理キー位置で判定する。
            if flags.contains(.control), flags.contains(.shift),
               !flags.contains(.command), !flags.contains(.option),
               ev.keyCode == 38 || ev.keyCode == 37,
               let terminal = fr as? LocalProcessTerminalView {
                terminal.interpretKeyEvents([ev])
                return nil
            }
            // ⌘K パレットが開いている間は、どの窓・どの firstResponder でも
            // このキー群がパレット操作になる (ターミナル窓から開いた場合も
            // ↑↓/⏎/Esc/⌘K が効く)。他のキーは素通し — パレットの TextField
            // にフォーカスがあれば入力され、なければ元の挙動のまま。
            if router.paletteOpen {
                if flags == .command, chars == "k" {
                    self.closePaletteRestoringFocus()
                    return nil
                }
                if flags == [] || flags == .shift {
                    switch ev.keyCode {
                    case 53: self.closePaletteRestoringFocus(); return nil   // Esc
                    case 125: router.paletteMove(1); return nil              // ↓
                    case 126: router.paletteMove(-1); return nil             // ↑
                    case 36: self.runPaletteRestoringFocus(); return nil     // ⏎
                    default: break
                    }
                }
            }
            // ⌘1…9 — tab/window navigation for standalone terminal windows.
            // In a system tab group the digit picks that tab; without one it
            // activates the Nth visible non-board window (same left→right /
            // top→bottom order as the restore list). The board window keeps
            // ⌘1 = goMain (handled further down), so it never applies here.
            if flags == .command, !flags.contains(.shift),
               !flags.contains(.control), !flags.contains(.option),
               let win = ev.window, !win.title.isEmpty, win.title != "AgentDeck",
               let tab = Self.tabDigit(chars) {
                if let target = Self.tabTarget(digit: tab, from: win) {
                    target.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    return nil
                }
                return ev
            }
            // Terminal focus owns the window. This branch MUST come before
            // the FM suggestion-bar feed below, and it must return in every
            // path: keys a shell owns (plain chars, ↑↓, Tab when nothing
            // completes) pass through to the terminal; app-level ⌘-keys are
            // claimed here so the menu equivalents (⌘F/⌘T/⌘R, ⌘⇧N/⌘⇧H/⌘⇧A)
            // can't fire behind the user's back; ⌘K (palette) stays
            // reachable from the shell with focus restored on close; ⌘1
            // puts the keyboard back on Main; ⌘⌘ toggles dictation.
            if let tv = fr as? TranslucentTerminalView {
                // ⌘⌘ (two unmodified command-key taps within 350ms) toggles
                // voice dictation. Modifier autorepeat while holding ⌘ and
                // any other key between the taps never arm the gesture.
                if (ev.keyCode == 55 || ev.keyCode == 54), !ev.isARepeat, flags == .command {
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - self.lastCmdTap < 0.35 {
                        self.lastCmdTap = 0
                        DebugLog.write("dictation toggle (terminal)")
                        DictationService.shared.toggle()
                    } else {
                        self.lastCmdTap = now
                    }
                    return ev
                }
                self.lastCmdTap = 0
                // ⌘K palette — captured before the app-cmd swallow so it
                // works while the embedded terminal holds focus, and the
                // terminal that had focus is restored when it closes.
                if flags == .command, chars == "k" {
                    if router.paletteOpen {
                        self.closePaletteRestoringFocus()
                    } else {
                        paletteTerminalView = tv
                        ev.window?.makeFirstResponder(nil)
                        router.openPalette()
                    }
                    return nil
                }
                // ⌘1 — leave the shell and put the keyboard back on Main
                // (board). Esc would misfire inside vim/readline, so the key
                // is verdict-free for shells. Board window only: standalone
                // terminal windows keep ⌘1 to themselves.
                let isBoard = (ev.window?.title ?? "").isEmpty || ev.window?.title == "AgentDeck"
                if isBoard, flags == .command, chars == "1" {
                    DebugLog.write("⌘1 terminal → goMain")
                    ev.window?.makeFirstResponder(nil)
                    router.fire(.goMain)
                    return nil
                }
                // ⌘+/⌘−/⌘0 — resize ONLY the focused pane's font. The right
                // panel and each terminal window keep their own zoom; ⌘= is
                // the same physical key as +, and JIS ⌘ー also zooms in.
                let typed = ev.characters ?? ""
                if flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
                   ["+", "=", "ー", "-", "0"].contains(typed) {
                    let pane = PaneZoom.paneID(for: tv)
                    switch typed {
                    case "-": PaneZoom.shared.adjust(pane, by: -1)
                    case "0": PaneZoom.shared.reset(pane)
                    default: PaneZoom.shared.adjust(pane, by: 1)
                    }
                    let level = PaneZoom.shared.zoom(pane)
                    tv.font = UISettings.shared.terminalFont(paneZoom: level)
                    DebugLog.write("pane font zoom \(pane) → \(level)")
                    return nil
                }
                let appCmd = flags == .command && ["f", "t", "r"].contains(chars)
                let appShiftCmd = flags == [.command, .shift] && ["n", "h", "a", "t"].contains(chars)
                if appCmd || appShiftCmd { return nil }
                // ⌘D ダッシュボード / ⌘, 設定 / ⌘W 窓を閉じる — ターミナルが
                // firstResponder のときもメニュー相当が確実に効くように、ここで
                // 明示的に請求して処理する (素通しするとシェルに吸われる)。
                if flags == .command, chars == "d" {
                    GlobalWindowActions.openDashboard?()
                    return nil
                }
                if flags == .command, chars == "," {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    return nil
                }
                if flags == .command, chars == "w", let win = ev.window {
                    win.performClose(nil)
                    return nil
                }
                // FM suggestion bar (any terminal, any window): feed the line
                // buffer, then accept via Tab/→ while suggestions are showing.
                // Only unmodified presses count and acceptance requires the
                // prediction to complete the typed line — ↑↓/Esc are never
                // stolen from the shell (Esc only closes the bar via noteKey).
                if TerminalPredictionSettings.enabled {
                    // NSEvent isn't Sendable, so only scalars cross into the
                    // MainActor context; the key routing happens inside it.
                    let keyCode = ev.keyCode
                    let chars = ev.characters
                    let hasCommand = flags.contains(.command)
                    let hasControl = flags.contains(.control)
                    nonisolated(unsafe) var consumed = false
                    MainActor.assumeIsolated {
                        guard let ctx = tv.context else { return }
                        ctx.noteKey(keyCode: keyCode, chars: chars, command: hasCommand, control: hasControl)
                        if !ctx.suggestions.isEmpty, flags == [] || flags == .shift {
                            switch keyCode {
                            case 48, 124: consumed = ctx.acceptIfCompletes()   // Tab, →
                            default: break
                            }
                        }
                    }
                    return consumed ? nil : ev
                }
                return ev
            }
            // ⌘⌘ (two unmodified command-key taps within 350ms) toggles
            // voice dictation. Modifier autorepeat while holding ⌘ and any
            // other key between the taps never arm the gesture.
            if (ev.keyCode == 55 || ev.keyCode == 54), !ev.isARepeat, flags == .command {
                let now = ProcessInfo.processInfo.systemUptime
                if now - self.lastCmdTap < 0.35 {
                    self.lastCmdTap = 0
                    DebugLog.write("dictation toggle (board)")
                    DictationService.shared.toggle()
                } else {
                    self.lastCmdTap = now
                }
                return ev
            }
            self.lastCmdTap = 0
            if fr is LocalProcessTerminalView { return ev }
            guard let win = ev.window else { return ev }
            // The main board window is the only place board keys live.
            // Terminal windows carry session titles and stay untouched.
            guard win.title == "AgentDeck" || win.title.isEmpty else { return ev }

            // ⌘K palette — handled before the terminal early-return so it
            // works while the embedded terminal holds focus (and the focus
            // captured here is restored when the palette closes).
            if flags == .command, chars == "k" {
                if router.paletteOpen {
                    self.closePaletteRestoringFocus()
                } else {
                    paletteTerminalView = ev.window?.firstResponder as? LocalProcessTerminalView
                    ev.window?.makeFirstResponder(nil)
                    router.openPalette()
                }
                return nil
            }

            // Command palette open: every key drives the palette, never the
            // board or the terminal. ↑↓/⏎/Esc/⌘K are global; everything
            // else types.
            if router.paletteOpen {
                if flags == [] || flags == .shift {
                    switch ev.keyCode {
                    case 53: self.closePaletteRestoringFocus(); return nil
                    case 125: router.paletteMove(1); return nil
                    case 126: router.paletteMove(-1); return nil
                    case 36: self.runPaletteRestoringFocus(); return nil
                    default: break
                    }
                }
                // Typing must reach the palette even when the first responder
                // is still the embedded terminal (SwiftUI field focus can
                // lose the race against the NSView responder). Only pass the
                // event through when a real text field holds focus, so IME
                // composition in the palette field keeps working.
                if let fr, fr is NSText || fr is NSTextField || fr is NSTextView {
                    return ev
                }
                if let s = ev.characters, !s.isEmpty, !flags.contains(.command), !flags.contains(.control) {
                    router.paletteQuery += s
                }
                return nil
            }

            // Embedded terminals (right panel) own their keys: board j/k/h/l
            // must never fire while the shell has focus. Suggestion keys were
            // already handled above, in the terminal branch.
            if fr is LocalProcessTerminalView { return ev }
            if let fr, fr is NSText || fr is NSTextField || fr is NSTextView { return ev }

            if flags == .command {
                switch chars {
                case "f": router.fire(.search); return nil
                case "t": router.fire(.newTerminal); return nil
                case "r": router.fire(.rescan); return nil
                case "1": router.fire(.goMain); return nil
                case "\r": router.fire(.openDetail); return nil
                default: break
                }
            }
            if flags == [.command, .shift] {
                switch chars {
                case "h": router.fire(.toggleHistory); return nil
                case "n": router.fire(.handoff); return nil
                case "a": router.fire(.archive); return nil
                default: break
                }
            }
            // Tab always cycles focus regions (board → header → sidebar),
            // even while a field is being edited — except when the detail
            // panel is showing, where Tab must move between its controls.
            if (flags == [] || flags == .shift) && ev.keyCode == 48,
               !KeyGate.detailPanelActive {
                router.fire(flags == .shift ? .focusPrev : .focusNext)
                return nil
            }
            // Bare keys must never fire while a text field is being edited
            // (Return would open terminals behind the user's back) or while
            // the detail panel owns the right side of the window.
            if KeyGate.suppressBoardKeys || KeyGate.detailPanelActive { return ev }
            if flags == [] || flags == .shift {
                switch ev.keyCode {
                case 125: router.fire(.moveNext); return nil
                case 126: router.fire(.movePrev); return nil
                case 124: router.fire(.openDetail); return nil   // →
                case 123: router.fire(.back); return nil         // ←
                case 53: router.fire(.goMain); return nil        // Esc
                default: break
                }
                switch chars {
                case "\r": router.fire(.openTerminal); return nil
                case "1": router.fire(.sidebarAll); return nil
                case "2": router.fire(.sidebarArchive); return nil
                case "3": router.fire(.sidebarRunning); return nil
                case "4": router.fire(.sidebarWaiting); return nil
                case "5": router.fire(.sidebarFailed); return nil
                case "6": router.fire(.sidebarDone); return nil
                case "j": router.fire(.moveNext); return nil
                case "k": router.fire(.movePrev); return nil
                case "l": router.fire(.openDetail); return nil
                case "h": router.fire(.back); return nil
                case "r": router.fire(.rename); return nil
                case "p": router.fire(.cycleProject); return nil
                case "x": router.fire(.sidebarAll); return nil
                case "g":
                    // vim-style: g g = top, ⇧G = bottom (shift bit in flags).
                    if flags.contains(.shift) {
                        router.fire(.goLast)
                        self.lastG = 0
                    } else {
                        let now = ProcessInfo.processInfo.systemUptime
                        if now - self.lastG < 0.4 {
                            router.fire(.goFirst)
                            self.lastG = 0
                        } else {
                            self.lastG = now
                        }
                    }
                    return nil
                default: break
                }
                // Finder-style type-ahead: bare printable keys narrow the
                // session list. Fields / IME / palette / terminals all return
                // before this point, so only genuine board focus reaches here.
                if chars.count == 1, let c = chars.first, c.isLetter || c.isNumber {
                    router.fire(.typeFilter(chars))
                    return nil
                }
            }
            return ev
        }
    }
}
