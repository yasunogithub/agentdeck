import SwiftUI
import AppKit

enum RightPanelTab: String, CaseIterable {
    case terminal = "ターミナル"
    case detail = "詳細"
    case handoff = "引継"
}

/// Keyboard focus helpers for the embedded terminal. SwiftUI FocusState
/// cannot target an NSView-representable PTY, so we make the first
/// TranslucentTerminalView in the key window the first responder directly.
/// The board's SwiftUI focus must be released first (onFocus callback) or
/// the hosting view re-asserts itself over the terminal's responder and
/// swallows the keystrokes back into the middle panel.
enum DeckFocus {
    @MainActor
    static func terminal(onFocused: (() -> Void)? = nil) {
        // 遅いログインシェル (resume の起動) でもクリック不要で入力できる
        // よう、リトライを 1.5 秒まで伸ばす。
        retry(attempts: 30, onFocused: onFocused)
    }

    @MainActor
    private static func retry(attempts: Int, onFocused: (() -> Void)?) {
        guard attempts > 0 else {
            DebugLog.write("DeckFocus: retries exhausted")
            return
        }
        guard let root = NSApp.keyWindow?.contentView, let t = find(in: root), t.window != nil else {
            // The panel is still laying out; the view isn't in the tree yet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                retry(attempts: attempts - 1, onFocused: onFocused)
            }
            return
        }
        let made = t.window?.makeFirstResponder(t) == true
        DebugLog.write("DeckFocus: attempt=\(13 - attempts) made=\(made)")
        if made {
            onFocused?()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                retry(attempts: attempts - 1, onFocused: onFocused)
            }
        }
    }

    @MainActor
    private static func find(in v: NSView) -> TranslucentTerminalView? {
        if let t = v as? TranslucentTerminalView { return t }
        for s in v.subviews {
            if let t = find(in: s) { return t }
        }
        return nil
    }
}

/// Draggable 6pt strip between two panes. Drags update the persisted pane
/// size; the cursor shows a resize grip while hovering.
struct PanelResizeDivider: View {
    @Binding var width: Double
    var range = 280.0...760.0
    /// When the divider sits at the pane's right edge (sidebar), dragging
    /// right must grow the pane; at its left edge (right panel) it shrinks.
    var growWithRightDrag = false
    @State private var dragStart: Double?

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        if dragStart == nil { dragStart = width }
                        let delta = growWithRightDrag ? v.translation.width : -v.translation.width
                        width = min(max(dragStart! + delta, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .help("ペイン幅を調整")
    }
}

/// Right-hand split pane of the board: live terminal (primary), session
/// detail, and the handoff tab (引継書 + 別エージェントへ引き継ぎ).
struct SessionRightPanel: View {
    let session: AgentSession
    @Binding var tab: RightPanelTab
    let mode: TerminalMode
    /// The caller sets this only after an explicit terminal activation and
    /// after any live tmux probe has completed.
    let terminalReady: Bool
    let onClose: () -> Void
    /// A collapsed panel must not retain a hidden PTY or its main-thread feed.
    var active = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $tab) {
                ForEach(RightPanelTab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ZStack {
                if active && tab == .terminal && terminalReady {
                    TerminalSheetView(session: session, mode: mode, embedded: true, showHeader: false)
                        .id(terminalInstanceID)
                } else if tab == .terminal {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("ターミナルを準備中…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if tab == .detail {
                    SessionDetailView(session: session, inPanel: true, onClose: onClose)
                        .id(session.key)
                }
                if tab == .handoff {
                    HandoffTabView(session: session)
                }
            }
        }
        .background(.background)
        .onAppear {
            if active && tab == .terminal && terminalReady { scheduleTerminalFocus() }
        }
        .onChange(of: tab) { _, newTab in
            if active && newTab == .terminal && terminalReady { scheduleTerminalFocus() }
        }
        .onChange(of: mode) { _, _ in
            if active && tab == .terminal && terminalReady { scheduleTerminalFocus() }
        }
        .onChange(of: terminalReady) { _, ready in
            if active && tab == .terminal && ready { scheduleTerminalFocus() }
        }
    }

    /// The PTY mounts one run-loop beat after the panel appears; wait a beat
    /// so the terminal is in the window before we make it first responder.
    private func scheduleTerminalFocus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { DeckFocus.terminal() }
    }

    /// Bump the instance when the launch mode changes (e.g. the async probe
    /// found a live tmux session: resume → attach), so the PTY restarts.
    private var terminalInstanceID: String {
        switch mode {
        case .resume: return "\(session.key)-resume"
        case .handoff: return "\(session.key)-handoff"
        case .handoffTo(let target): return "\(session.key)-handoff-\(target)"
        case .comment: return "\(session.key)-comment"
        case .attach(let name): return "\(session.key)-attach-\(name)"
        case .bare: return "\(session.key)-bare"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(session.state.color).frame(width: 9, height: 9)
                Text(session.title).font(.headline).lineLimit(1)
                Text(TerminalSheetView.modeLabel(mode))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
                Spacer()
                Button { RepoTools.revealInFinder(session) } label: {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Finderで開く")
                Button { RepoTools.openPR(session) } label: {
                    Image(systemName: "globe")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("GitHubで開く")
                Button { RepoTools.copyHandoff(session) } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("引継書をクリップボードにコピー")
                Button { onClose() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("右パネルを閉じる (←/h)")
            }
            HStack(spacing: 8) {
                Label(session.repoName, systemImage: "folder")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(session.cwd ?? session.project)
                if let branch = session.branch {
                    Text("⎇ \(branch)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("gitブランチ")
                }
                if let pr = session.prState, pr != "none" {
                    prChip(pr)
                }
                if session.hasWorktree {
                    Text("wt").font(.caption2.weight(.semibold)).foregroundStyle(.purple)
                }
                Spacer()
                Text(SessionStore.relativeAge(session.lastActivity))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
    }

    private func prChip(_ pr: String) -> some View {
        let label = pr == "MERGED" ? "merged" : pr == "OPEN" ? "open" : "closed"
        let color: Color = pr == "MERGED" ? .green : pr == "OPEN" ? .yellow : .red
        return Text("PR #\(session.prNumber.map { String($0) } ?? "?") \(label)")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

/// 引継 tab: the auto-generated handoff brief (引継書), the branch/worktree
/// identity, a target-agent picker, and one-click launches (copy / new
/// terminal / Finder / GitHub) so a session survives a change of agent.
struct HandoffTabView: View {
    let session: AgentSession
    @State private var target: String = "pi"
    @Environment(\.openWindow) private var openWindow

    private let agents = ["pi", "deepseek", "qwen", "claude-code", "opencode2", "codex"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let branch = session.branch {
                    chip("⎇ \(branch)", color: .teal, help: "ブランチ")
                }
                if session.hasWorktree {
                    chip("wt \(session.repoName)", color: .purple, help: "git worktree")
                }
                if let pr = session.prState, pr != "none" {
                    chip("PR #\(session.prNumber.map { String($0) } ?? "?") \(pr.lowercased())",
                         color: pr == "MERGED" ? .green : pr == "OPEN" ? .yellow : .red, help: "Pull Request")
                }
                Spacer()
                if let cwd = session.cwd {
                    Text(cwd)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(cwd)
                }
            }
            Picker("引き継ぐエージェント", selection: $target) {
                ForEach(agents, id: \.self) { Text($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 8) {
                Button {
                    RepoTools.copyHandoff(session)
                } label: {
                    Label("引継書をコピー", systemImage: "doc.on.doc")
                }
                .help("クリップボードにコピーして別のアプリ/エージェントへ")
                Button {
                    openWindow(id: "terminal", value: "handoffto:\(target)\n\(session.key)")
                } label: {
                    Label("\(target) で引き継ぐ", systemImage: "arrow.forward.square")
                }
                .keyboardShortcut(.return, modifiers: [.command])
                Spacer()
                Button { RepoTools.revealInFinder(session) } label: {
                    Image(systemName: "folder").help("Finderで開く")
                }
                Button { RepoTools.openPR(session) } label: {
                    Image(systemName: "globe").help("GitHubで開く")
                }
            }
            .controlSize(.small)
            Divider()
            Text("引継書（自動生成・常に最新 — ブランチと作業ディレクトリがあれば復元可能）")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ScrollView {
                MarkdownView(text: HandoffBrief.text(session))
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.12)))
            }
        }
        .padding(12)
        .onAppear {
            // Default: an agent *other* than the one that did the work.
            if target == session.agent {
                target = agents.first { $0 != session.agent } ?? "pi"
            }
        }
    }

    private func chip(_ text: String, color: Color, help: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .help(help)
    }
}
