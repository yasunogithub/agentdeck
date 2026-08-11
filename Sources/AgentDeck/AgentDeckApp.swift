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
            CommandMenu("セッション") {
                // No Return/⌘⏎ key equivalents here: menu equivalents fire even
                // while the search field is editing, opening terminals behind the
                // user's back. The board window's NSEvent monitor owns those keys.
                Button("コマンドパレット") { HotkeyRouter.shared.fire(.palette) }
                    .keyboardShortcut("k", modifiers: .command)
                Button("新規ターミナル") { HotkeyRouter.shared.fire(.newTerminal) }
                    .keyboardShortcut("t", modifiers: .command)
                Button("ターミナルを開く") { HotkeyRouter.shared.fire(.openTerminal) }
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

        Settings {
            SettingsView()
        }
    }
}

struct DetailWindowRoot: View {
    let key: String
    @ObservedObject private var store = SessionStore.shared

    var body: some View {
        if let session = store.sessions.first(where: { $0.key == key }) {
            SessionDetailView(session: session, onClose: { })
                .frame(minWidth: 580, minHeight: 460)
        } else {
            Text("セッションが見つかりません: \(key)")
                .foregroundStyle(.secondary)
        }
    }
}

struct TerminalWindowRoot: View {
    let spec: String
    @ObservedObject private var store = SessionStore.shared
    @ObservedObject private var ui = UISettings.shared

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
                TerminalSheetView(session: session, mode: mode)
                    .navigationTitle(windowTitle(for: session))
            } else {
                Text("セッションが見つかりません: \(key)")
                    .foregroundStyle(.secondary)
            }
        }
        .windowTransparency(ui.terminalOpacity)
    }

    /// The window/tab title carries the same meta the board card shows,
    /// so merged tabs and the ⌘⇧` switcher are tellable apart at a glance.
    private func windowTitle(for s: AgentSession) -> String {
        var t = "\(s.title) ・ \(s.agent)/\(s.project)"
        if let b = s.branch { t += " ⎇ \(b)" }
        if let pr = s.prNumber {
            t += " · PR #\(pr)\(s.prState == "MERGED" ? " merged" : "")"
        }
        t += " [\(s.state.label)]"
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        server.start()
        mcp.start()
        TranscriptScanner.shared.start()
        installKeyMonitor()
        installSwipeMonitor()
        loadAppIcon()
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
            let frType = fr.map { String(describing: type(of: $0)) } ?? "nil"
            DebugLog.write("key keyCode=\(ev.keyCode) chars='\(chars)' flags=\(flags.rawValue) fr=\(frType) win='\(ev.window?.title ?? "")'")
            // ⌃⇧J (ATOK IME toggle) must reach the input method before
            // SwiftTerm converts it into a control byte. Route only this
            // exact combo through interpretKeyEvents; plain ⌃J keeps
            // SwiftTerm's native LF conversion.
            if flags.contains(.control), flags.contains(.shift),
               !flags.contains(.command), !flags.contains(.option),
               chars == "j",
               let terminal = fr as? LocalProcessTerminalView {
                terminal.interpretKeyEvents([ev])
                return nil
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
                let appCmd = flags == .command && ["f", "t", "r"].contains(chars)
                let appShiftCmd = flags == [.command, .shift] && ["n", "h", "a"].contains(chars)
                if appCmd || appShiftCmd { return nil }
                // FM suggestion bar (any terminal, any window): feed the line
                // buffer, then accept via Tab/→ while suggestions are showing.
                // Only unmodified presses count and acceptance requires the
                // prediction to complete the typed line — ↑↓/Esc are never
                // stolen from the shell (Esc only closes the bar via noteKey).
                if let ctx = tv.context {
                    // NSEvent isn't Sendable, so only scalars cross into the
                    // MainActor context; the key routing happens inside it.
                    let keyCode = ev.keyCode
                    let chars = ev.characters
                    let hasCommand = flags.contains(.command)
                    let hasControl = flags.contains(.control)
                    nonisolated(unsafe) var consumed = false
                    MainActor.assumeIsolated {
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
                case "a": router.fire(.cycleAgent); return nil
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
            }
            return ev
        }
    }
}
