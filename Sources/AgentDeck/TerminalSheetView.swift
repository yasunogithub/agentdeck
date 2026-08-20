import SwiftUI
import SwiftTerm

enum TerminalMode: Equatable {
    case resume
    case handoff
    /// Hand off to a *different* agent (引継: qwen ↔ claude-code ↔ opencode2 ↔ pi ↔ deepseek).
    case handoffTo(String)
    case comment(String)
    /// Live mirror of an already-running terminal via tmux multi-attach.
    case attach(String)
    /// Plain interactive shell in a folder — the deck's own "new terminal".
    case bare(String)
}

/// Embedded real-PTY terminal for a session:
/// - resume:  `qwen/claude --resume <id>` (history replays, continue live)
/// - comment: `--resume <id> "<text>"` (your comment becomes the next turn)
/// - handoff: fresh session seeded with a distilled handoff brief
/// - bare:    plain zsh in a folder (no agent attached)
struct TerminalSheetView: View {
    let session: AgentSession
    var mode: TerminalMode = .resume
    /// Right-panel layout: no min frame, no window-level translucency.
    var embedded = false
    /// Bare terminal mode: no header strip (the panel has its own).
    var showHeader = true
    @StateObject private var context = TerminalContext()
    @Environment(\.dismiss) private var dismiss

    static func modeLabel(_ mode: TerminalMode) -> String {
        switch mode {
        case .resume: "--resume"
        case .handoff: "handoff"
        case .handoffTo(let target): "handoff→\(target)"
        case .comment: "コメント送信"
        case .attach: "ライブattach"
        case .bare: "新規ターミナル"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showHeader {
                header
                Divider()
            }
            ZStack(alignment: .bottom) {
                TerminalHostView(session: session, mode: mode, embedded: embedded, context: context)
                if !context.suggestions.isEmpty {
                    SuggestionBar(context: context)
                        .padding(6)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .frame(minWidth: embedded ? 0 : 720, minHeight: embedded ? 0 : 420)
        .overlay(alignment: .top) {
            if !embedded && dictation.active {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").foregroundStyle(.red)
                    Text(dictation.interim.isEmpty ? "音声入力中… ⌘⌘ で確定" : dictation.interim)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.red.opacity(0.35)))
                .padding(.top, 8)
            }
        }
    }

    @ObservedObject private var dictation: DictationService = .shared
    @ObservedObject private var ui = UISettings.shared

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle().fill(session.state.color).frame(width: 9, height: 9)
                Text(ui.headerFont(session.title, size: 17, weight: .semibold)).lineLimit(1)
                Text(ui.headerFont("\(session.agent) \(Self.modeLabel(mode))", size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 10) {
                Label {
                    Text(ui.headerFont(session.repoName, size: 15, weight: .semibold))
                } icon: {
                    Image(systemName: "folder")
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(session.cwd ?? session.project)
                if let branch = session.branch {
                    Text(ui.headerFont("⎇ \(branch)", size: 15))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let pr = session.prState, pr != "none" {
                    let label = pr == "MERGED" ? "merged" : pr == "OPEN" ? "open" : "closed"
                    Text(ui.headerFont("PR #\(session.prNumber.map { String($0) } ?? "?") \(label)", size: 11, weight: .semibold))
                        .foregroundStyle(pr == "MERGED" ? .green : pr == "OPEN" ? .yellow : .red)
                }
                if let cwd = session.cwd {
                    Text(cwd)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(cwd)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // Opaque strip even when the window is translucent, so the title
        // stays readable over the desktop.
        .background(Color(white: 0.1))
    }
}

/// SwiftTerm 1.15 converts Ctrl+letter straight into a control byte
/// (Ctrl+J = LF) before the input method ever sees the event, so ATOK's
/// IME-toggle hotkey (Ctrl+Shift+J) dies as a newline. The keyDown override
/// that rerouted this is gone (non-open upstream now), so AgentDeckApp's
/// local key monitor intercepts the exact ⌃⇧J combo and routes it through
/// interpretKeyEvents; plain ⌃J keeps SwiftTerm's native LF behavior.
///
/// Also applies the configured translucency (UISettings.terminalOpacity):
/// the view keeps an alpha'd background and, when alpha < 1, the hosting
/// window is made non-opaque so the desktop shows through (iTerm style).
/// Embedded (right-panel) terminals skip the window-level change — the board
/// window must stay opaque.
final class TranslucentTerminalView: LocalProcessTerminalView {
    /// Skip window-level translucency (embedded in the board panel).
    var embedded = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyOpacity()
        if window != nil {
            enableMetalRenderer()
        }
    }

    /// GPU 描画へ移行する (CPU で全行 NSAttributedString を組み立てる描画を
    /// 止め、メインスレッドの負荷を下げる)。半透明ウィンドウでも clearColor
    /// に nativeBackgroundColor のアルファが渡るので透過合成は維持される。
    /// SwiftUI がビューをウィンドウ間で移動させると Metal バインドが
    /// リセットされることがあるため、ウィンドウ移動のたびに再試行する
    /// (setUseMetal は既に有効なときは何もしない)。失敗時は CPU 描画のまま。
    private func enableMetalRenderer() {
        do {
            try setUseMetal(true)
            if !metalLogged {
                metalLogged = true
                NSLog("AgentDeck: Metal レンダラー有効化 OK")
            }
        } catch {
            if !metalLogged {
                metalLogged = true
                NSLog("AgentDeck: Metal 有効化をスキップ (CPU描画フォールバック): \(error)")
            }
        }
    }

    private var metalLogged = false

    private var metalEnabledOnce = false

    func applyOpacity() {
        let alpha = UISettings.shared.terminalOpacity
        nativeBackgroundColor = NSColor(red: 0.07, green: 0.08, blue: 0.10, alpha: alpha)
        layer?.backgroundColor = nativeBackgroundColor.cgColor
        guard !embedded else { return }
        if let window {
            let translucent = alpha < 0.999
            window.isOpaque = !translucent
            window.backgroundColor = translucent ? .clear : nil
        }
    }

    /// High-contrast dark scheme: a light default foreground so text never
    /// inherits the system appearance's `textColor` (black in light mode),
    /// and a bright ANSI palette — SwiftTerm's stock palette uses near-black
    /// dark colors (#990001 red etc.) that read as dim gray smudges on dark
    /// backgrounds. This is the "薄灰色で見づらい" fix.
    func applyHighContrastScheme() {
        nativeForegroundColor = NSColor(red: 0.86, green: 0.88, blue: 0.93, alpha: 1)
        installColors(Self.brightPalette)
    }

    static let brightPalette: [SwiftTerm.Color] = [
        TranslucentTerminalView.rgb8(65, 72, 89),       // black  (dark gray, not #000)
        TranslucentTerminalView.rgb8(230, 94, 92),      // red
        TranslucentTerminalView.rgb8(144, 190, 118),    // green
        TranslucentTerminalView.rgb8(250, 208, 123),    // yellow
        TranslucentTerminalView.rgb8(96, 156, 230),     // blue
        TranslucentTerminalView.rgb8(180, 142, 227),    // magenta
        TranslucentTerminalView.rgb8(98, 201, 209),     // cyan
        TranslucentTerminalView.rgb8(208, 213, 224),    // white
        TranslucentTerminalView.rgb8(118, 125, 143),    // bright black
        TranslucentTerminalView.rgb8(255, 122, 120),    // bright red
        TranslucentTerminalView.rgb8(166, 220, 140),    // bright green
        TranslucentTerminalView.rgb8(255, 222, 150),    // bright yellow
        TranslucentTerminalView.rgb8(130, 184, 255),    // bright blue
        TranslucentTerminalView.rgb8(208, 162, 255),    // bright magenta
        TranslucentTerminalView.rgb8(120, 225, 233),    // bright cyan
        TranslucentTerminalView.rgb8(255, 255, 255),    // bright white
    ]

    /// 8-bit component → SwiftTerm's 16-bit color (x * 257).
    private static func rgb8(_ r: UInt16, _ g: UInt16, _ b: UInt16) -> SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16(r) &* 257, green: UInt16(g) &* 257, blue: UInt16(b) &* 257)
    }

    /// Keys that drive the FM suggestion bar before the shell sees them are
    /// routed by AppDelegate's key monitor (LocalProcessTerminalView methods
    /// are non-open, so we cannot override keyDown). This class only holds
    /// the shared context reference used by that routing.
    weak var context: TerminalContext?
}

struct TerminalHostView: NSViewRepresentable {
    let session: AgentSession
    var mode: TerminalMode = .resume
    var embedded = false
    var context: TerminalContext? = nil

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = TranslucentTerminalView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        view.processDelegate = context.coordinator
        view.embedded = embedded
        view.context = self.context
        self.context?.attach(view)
        view.applyOpacity()
        view.applyHighContrastScheme()
        applyFont(to: view)
        // Window is nil at make-time and the pane zoom of standalone windows
        // is windowNumber-based — re-apply the font once the view joins one.
        DispatchQueue.main.async { [weak view] in
            if let view { applyFont(to: view) }
        }

        let env = ProcessInfo.processInfo.environment
            .map { "\($0.key)=\($0.value)" } + ["TERM=xterm-256color"]

        view.startProcess(
            executable: "/bin/zsh",
            args: ["-l", "-c", command],
            environment: env,
            currentDirectory: SafeCwd.resolve(session.cwd) ?? FileManager.default.homeDirectoryForCurrentUser.path
        )
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        if let view = nsView as? TranslucentTerminalView {
            view.embedded = embedded
            view.context = self.context
            self.context?.attach(view)
        }
        applyFont(to: nsView)
    }

    /// SwiftTerm intentionally does not SIGTERM its child from `deinit`.
    /// SwiftUI can dismantle an NSViewRepresentable while the process is
    /// still alive, so explicitly terminate the PTY here.
    func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        if let view = nsView as? TranslucentTerminalView {
            view.context?.detach(view)
        }
        nsView.processDelegate = nil
        if nsView.process?.running == true {
            nsView.terminate()
        }
    }

    /// Larger, higher-contrast default font. SwiftTerm's stock 13pt system
    /// font renders small on a big window; honour the user's fontFamily
    /// when set, otherwise Menlo at 15pt (readable on dark backgrounds).
    /// The size shifts by this pane's own ⌘+/- level (PaneZoom), so each
    /// pane keeps its own scale.
    private func applyFont(to view: LocalProcessTerminalView) {
        let ui = UISettings.shared
        let paneID = PaneZoom.paneID(for: view)
        let font = ui.terminalFont(paneZoom: PaneZoom.shared.zoom(paneID))
        if view.font.fontName != font.fontName || view.font.pointSize != font.pointSize {
            view.font = font
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private var binary: String {
        switch session.agent {
        case "claude-code": "claude"
        case "codex": "codex"
        case "opencode2": "opencode2"
        case "pi": "pi"
        case "deepseek": "open"
        default: "pi"
        }
    }

    private var command: String {
        let id = Self.shellQuote(session.sessionId)
        switch (session.agent, mode) {
        case (_, .bare):
            return "zsh -l"
        case (_, .handoffTo(let target)):
            let text = Self.shellQuote(HandoffBrief.text(session))
            switch target {
            case "claude-code": return "echo '— handoff開始 —'; claude \(text)"
            case "codex": return "echo '— handoff開始 —'; codex exec \(text)"
            case "opencode2": return "echo '— handoff開始 —'; opencode2 --auto --prompt \(text)"
            case "pi": return "echo '— handoff開始 —'; pi \(text)"
            case "deepseek": return "echo '— handoff開始 — DeepSeek Harness で開きます (引継書はクリップボード/右パネルにあります)'; open -a 'DeepSeek Harness'"
            default: return "echo '— handoff開始 —'; pi \(text)"
            }
        case ("claude-code", .resume):
            return "claude --resume \(id)"
        case ("claude-code", .comment(let text)):
            return "claude --resume \(id) \(Self.shellQuote(text))"
        case ("claude-code", .handoff):
            let text = Self.shellQuote(HandoffBrief.text(session))
            return "echo '— handoff開始 —'; claude \(text)"
        case ("opencode2", .resume):
            return "opencode2 --auto --session \(id)"
        case ("opencode2", .comment(let text)):
            return "opencode2 --auto --session \(id) --prompt \(Self.shellQuote(text))"
        case ("opencode2", .handoff):
            let text = Self.shellQuote(HandoffBrief.text(session))
            return "echo '— handoff開始 —'; opencode2 --auto --prompt \(text)"
        case ("codex", .resume):
            // `codex resume <uuid>` re-enters the TUI for that session
            return "codex resume \(id)"
        case ("codex", .comment(let text)):
            return "codex resume \(id) \(Self.shellQuote(text))"
        case ("codex", .handoff):
            let text = Self.shellQuote(HandoffBrief.text(session))
            return "echo '— handoff開始 —'; codex exec \(text)"
        case ("pi", .resume):
            // `pi --session <uuid>` re-enters the TUI for that session file
            return "pi --session \(id)"
        case ("pi", .comment(let text)):
            // -p processes the prompt non-interactively and appends to the
            // same session file; the board picks up the new turn via FSEvents.
            return "pi --session \(id) -p \(Self.shellQuote(text))"
        case ("pi", .handoff):
            let text = Self.shellQuote(HandoffBrief.text(session))
            return "echo '— handoff開始 —'; pi \(text)"
        case ("deepseek", .resume):
            // DeepSeek Harness is a web TUI with no CLI — open the app; its
            // workspace list shows the session to pick up.
            return "open -a 'DeepSeek Harness'"
        case ("deepseek", .comment(_)):
            return "open -a 'DeepSeek Harness'"
        case ("deepseek", .handoff):
            return "echo '— handoff開始 — DeepSeek Harness で開きます (引継書はクリップボード/右パネルにあります)'; open -a 'DeepSeek Harness'"
        case (_, .resume):
            return "pi --session \(id)"
        case (_, .comment(let text)):
            return "pi --session \(id) -p \(Self.shellQuote(text))"
        case (_, .handoff):
            let text = Self.shellQuote(HandoffBrief.text(session))
            return "echo '— handoff開始 —'; pi \(text)"
        case (_, .attach(let name)):
            // '=' forces an exact match; quote it too, or zsh's =word
            // equals-expansion tries to resolve it as a command path.
            // Detach with Ctrl-b d; the original terminal keeps running.
            return "tmux attach -t \(Self.shellQuote("=\(name)"))"
        }
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {}
    }
}
