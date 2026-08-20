import Foundation
import SwiftUI

enum TerminalPredictionSettings {
    /// User opt-in for the latency-sensitive Foundation Models ghost bar.
    nonisolated static var enabled: Bool {
        UserDefaults.standard.bool(forKey: "adEnableTerminalPredictions")
    }
}

/// Per-terminal state for the FM command-suggestion bar: best-effort tracking
/// of the current shell line, debounced next-command prediction via Apple
/// Foundation Models, and Tab/→ acceptance.
@MainActor
final class TerminalContext: ObservableObject {
    /// Terminal command prediction is an explicit opt-in. It starts a new
    /// Foundation Models session after a pause in typing and is therefore not
    /// part of the latency-sensitive default shell path.
    @Published private(set) var line = ""
    @Published private(set) var suggestions: [String] = []
    @Published private(set) var highlighted = 0
    @Published private(set) var predicting = false

    weak var terminal: TranslucentTerminalView?
    private var predictTask: Task<Void, Never>?
    private var generation = 0
    /// Minimum gap between two Foundation Models calls, so fast typing can't
    /// queue a prediction per pause (each call is a real on-device LLM run).
    private var lastPredict: Date = .distantPast

    func attach(_ terminal: TranslucentTerminalView) {
        self.terminal = terminal
    }

    func detach(_ terminal: TranslucentTerminalView) {
        if self.terminal === terminal { self.terminal = nil }
        predictTask?.cancel()
        predictTask = nil
    }

    /// Called from the key monitor for every key the user types at the shell
    /// prompt (best-effort — completions, bracketed-paste and IME text are
    /// approximated). Only Sendable scalars cross the actor boundary.
    func noteKey(keyCode: UInt16, chars: String?, command: Bool, control: Bool) {
        guard TerminalPredictionSettings.enabled else { return }
        switch keyCode {
        case 36, 76:
            line = ""
            suggestions = []
        case 51:
            if !line.isEmpty { line.removeLast() }
        case 53:
            // Esc closes the bar *without* eating the key itself — the shell
            // (vim, readline, TUI cancel) still receives it.
            suggestions = []
            predicting = false
        default:
            if let chars, chars.count == 1, !command, !control,
               let c = chars.unicodeScalars.first, c.value >= 32, c.value < 127 {
                line.append(Character(chars))
            }
        }
        predict()
    }

    /// Tab/→ while suggestions are showing: accept ONLY when the highlighted
    /// prediction actually completes what was typed (prefix match). Anything
    /// else falls through to the shell's own Tab (zsh completion), so a
    /// wrong or unrelated guess can never wipe the user's line.
    func acceptIfCompletes() -> Bool {
        guard !suggestions.isEmpty, let terminal else { return false }
        let cmd = suggestions[min(max(highlighted, 0), suggestions.count - 1)]
        let typed = line.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, cmd.lowercased().hasPrefix(typed.lowercased()) else { return false }
        // Kill the line (Ctrl+U — zsh/bash default) and type the command,
        // so the user can review it and press Enter.
        terminal.send(txt: "\u{15}" + cmd)
        line = cmd
        suggestions = []
        predicting = false
        return true
    }

    /// Click on a chip: explicit intent, so any suggestion may be accepted
    /// (no prefix constraint — the user chose it deliberately).
    func acceptSuggestion() {
        guard !suggestions.isEmpty, let terminal else { return }
        let cmd = suggestions[min(max(highlighted, 0), suggestions.count - 1)]
        terminal.send(txt: "\u{15}" + cmd)
        line = cmd
        suggestions = []
        predicting = false
    }

    func dismissSuggestions() {
        suggestions = []
        predicting = false
    }

    /// Click on a chip: highlight it and accept it.
    func selectAndAccept(_ index: Int) {
        guard !suggestions.isEmpty else { return }
        highlighted = min(max(index, 0), suggestions.count - 1)
        acceptSuggestion()
    }

    private func predict() {
        guard TerminalPredictionSettings.enabled else { return }
        predictTask?.cancel()
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.count >= 3 else {
            suggestions = []
            predicting = false
            return
        }
        let gen = generation + 1
        generation = gen
        let fm = FMService.shared
        predicting = true
        predictTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            // Cooldown between real FM calls: bail (keep current suggestions)
            // if the last call was <1.5s ago instead of firing another one.
            if let self, Date().timeIntervalSince(self.lastPredict) < 1.5 {
                self.predicting = false
                return
            }
            let result = await fm.nextCommands(prefix: String(text.prefix(80)))
            guard let self, self.generation == gen, !Task.isCancelled else { return }
            self.lastPredict = Date()
            self.suggestions = result
            self.highlighted = 0
            self.predicting = false
        }
    }
}

/// Faint bar under the terminal showing the predicted next commands.
/// Tab/→ accepts the highlighted one; ↑↓ cycle; Esc dismisses.
struct SuggestionBar: View {
    @ObservedObject var context: TerminalContext

    private struct ChipRow: Identifiable {
        let id = UUID()
        let index: Int
        let command: String
        let highlighted: Bool
    }

    private var chipRows: [ChipRow] {
        context.suggestions.enumerated().map { i, command in
            ChipRow(index: i, command: command, highlighted: i == context.highlighted)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if context.predicting && context.suggestions.isEmpty {
                ProgressView().controlSize(.mini)
            }
            ForEach(chipRows) { row in
                chip(row)
            }
            Spacer()
            hint
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.06)))
        .help("Apple Foundation Models が次のコマンドを推測")
    }

    private var hint: some View {
        Text("Tab/→ 採用 · Esc で閉じる · クリック選択")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    private func chip(_ row: ChipRow) -> some View {
        let fill: Color = row.highlighted ? Color.accentColor.opacity(0.2) : Color.white.opacity(0.06)
        let textColor: Color = row.highlighted ? Color.primary : Color.secondary
        let arrowColor: Color = row.highlighted ? Color.accentColor : Color.gray
        return HStack(spacing: 4) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(arrowColor)
            Text(row.command)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(fill))
        .contentShape(Rectangle())
        .onTapGesture {
            select(row.index)
        }
    }

    private func select(_ index: Int) {
        context.selectAndAccept(index)
    }
}
