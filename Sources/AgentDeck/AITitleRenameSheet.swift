import SwiftUI

/// AI title rename modal. Opens from the card context menu, generates a
/// transcript-derived title on-device (FM), lets the user edit it, and
/// applies via `onApply`. The original title is kept in `original` and can be
/// restored with 元に戻す / simply by cancelling — applying is the only
/// mutation, and even then the original stays one click away in the sheet.
struct AITitleRenameSheet: View {
    let session: AgentSession
    let onApply: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Title captured when the sheet opened — never touched until 適用.
    private let original: String
    @State private var draft = ""
    @State private var busy = false
    @State private var note: String?
    @State private var didAutoGenerate = false
    @FocusState private var fieldFocused: Bool

    init(session: AgentSession, onApply: @escaping (String) -> Void) {
        self.session = session
        self.onApply = onApply
        self.original = session.title  // captured before any user edit
        _draft = State(initialValue: session.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                Text("AIでタイトル生成")
                    .font(.headline)
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("元のタイトル")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                HStack(spacing: 6) {
                    Text(original)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer()
                    Button("元に戻す") {
                        draft = original
                        fieldFocused = true
                    }
                    .controlSize(.small)
                    .disabled(draft == original)
                    .help("AI候補を使わず元のタイトルに戻す")
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("新しいタイトル（編集可）")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                TextField("タイトル…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit { apply() }
            }

            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(FMService.shared.isAvailable ? Color.secondary : Color.orange)
            }

            HStack {
                Button("再生成") { regenerate() }
                    .disabled(busy || !FMService.shared.isAvailable)
                    .help("FMでもう一度生成")
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("適用") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            guard !didAutoGenerate else { return }
            didAutoGenerate = true
            if FMService.shared.isAvailable {
                regenerate()
            } else {
                note = "Apple Intelligence (FM) が無効のためAI生成はできません。手動で編集して適用できます。"
            }
            // Keep board hotkeys dead while the modal owns the keyboard.
            KeyGate.suppressBoardKeys = true
        }
        .onDisappear {
            KeyGate.suppressBoardKeys = false
        }
    }

    private func regenerate() {
        guard !busy, FMService.shared.isAvailable else { return }
        busy = true
        note = nil
        let path = session.transcriptPath
        Task {
            let turns = path.map { TranscriptReader.turns(path: $0) } ?? []
            let compressed = turns.suffix(30).map { turn in
                let cap = turn.role == "user" ? 250 : 200
                return "\(turn.role == "user" ? "ユーザー" : "AI"): \(String(turn.text.prefix(cap)))"
            }
            .joined(separator: "\n")
            guard !Task.isCancelled else { return }
            let suggested = await FMService.shared.suggestTitle(transcript: compressed)
            guard !Task.isCancelled else { return }
            busy = false
            if let suggested, !suggested.isEmpty {
                draft = suggested
                fieldFocused = true
            } else {
                note = "タイトルを生成できませんでした。手動で編集して適用できます。"
            }
        }
    }

    private func apply() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        onApply(t)
        dismiss()
    }
}