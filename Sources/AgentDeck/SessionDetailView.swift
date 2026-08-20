import SwiftUI

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String
    let text: String
}

struct SessionDetailView: View {
    let session: AgentSession
    /// Right-panel embedding: drop the min-window frames that would blow up
    /// the 520px panel.
    var inPanel = false
    @Environment(\.dismiss) private var dismiss
    /// Overlay presentation: the board closes us by nil-ing its selection.
    var onClose: () -> Void = {}
    var onAttach: (() -> Void)? = nil
    @Environment(\.openWindow) private var openWindow

    @State private var tab: Tab = .history
    @State private var messages: [ChatMessage] = []
    @State private var input = ""
    @FocusState private var inputFocused: Bool
    @State private var busy = false
    @State private var turns: [Turn] = []
    @State private var artifacts: [String] = []
    @State private var artifactSelection: String?
    @State private var summary: String?
    @State private var summaryBusy = false
    @State private var summaryTask: Task<Void, Never>?
    @State private var summaryExpanded = true
    /// Unique URLs found in the transcript, listed as clickable links.
    @State private var links: [String] = []
    @State private var linksExpanded = true

    private struct LoadedSession: Sendable {
        let turns: [Turn]
        let artifacts: [String]
        let summary: String?
        let links: [String]
    }

    /// 右パネルの詳細はこの3つに統廃合:
    /// 履歴(要約+資料リンク+トランスクリプト) / 資料(HTML・画像・PDF) / AIチャット。
    /// ハンドオフは右パネル上部の「引継」タブが担う(重複削除)。
    enum Tab: String, CaseIterable {
        case history = "履歴"
        case artifacts = "資料"
        case chat = "AIチャット"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            switch tab {
            case .history:
                historyArea
                commentBar
            case .artifacts:
                ArtifactBrowserView(paths: artifacts, selection: $artifactSelection)
            case .chat:
                chatArea
                inputBar
            }
        }
        .workspaceOpenURL()
        .frame(minWidth: inPanel ? 0 : 620, minHeight: inPanel ? 220 : 520)
        .task(id: session.key) {
            await reloadSession()
        }
        .onChange(of: tab) { _, newTab in
            if newTab == .history, summary == nil, !turns.isEmpty {
                generateSummary()
            }
        }
        .onDisappear {
            summaryTask?.cancel()
            summaryTask = nil
            inputFocused = false
            KeyGate.suppressBoardKeys = false
        }
    }

    /// Reload all session-owned state when the panel follows another session.
    /// Transcript and HTML parsing is detached from the main actor; only the
    /// small result snapshot is published back into SwiftUI.
    private func reloadSession() async {
        summaryTask?.cancel()
        summaryTask = nil
        turns = []
        artifacts = []
        artifactSelection = nil
        summary = nil
        messages = []
        input = ""
        tab = .history
        busy = false
        summaryBusy = false
        inputFocused = false

        let key = session.key
        let path = session.transcriptPath
        let mtime = session.lastActivity
        let loaded = await Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else {
                return LoadedSession(turns: [], artifacts: [], summary: nil, links: [])
            }
            let parsedTurns = path.map { TranscriptReader.turns(path: $0) } ?? []
            guard !Task.isCancelled else {
                return LoadedSession(turns: parsedTurns, artifacts: [], summary: nil, links: [])
            }
            let paths = path.map { TranscriptReader.artifactPaths(path: $0) } ?? []
            let cached = SummaryCache.get(key, mtime: mtime)
            let links = Linkifier.urls(in: parsedTurns.map(\.text))
            return LoadedSession(turns: parsedTurns, artifacts: paths, summary: cached, links: links)
        }.value

        guard !Task.isCancelled, session.key == key else { return }
        turns = loaded.turns
        artifacts = loaded.artifacts
        artifactSelection = loaded.artifacts.first
        summary = loaded.summary
        links = loaded.links
        if tab == .history, summary == nil, !turns.isEmpty {
            generateSummary()
        }
    }

    // MARK: summary (履歴タブ内に統合)

    private func generateSummary() {
        guard !summaryBusy else { return }
        summaryTask?.cancel()
        summaryBusy = true
        let compressed = turns.map { turn in
            let cap = turn.role == "user" ? 250 : 200
            return "\(turn.role == "user" ? "ユーザー" : "AI"): \(String(turn.text.prefix(cap)))"
        }
        .joined(separator: "\n")
        let key = session.key
        let mtime = session.lastActivity
        summaryTask = Task {
            let result = await FMService.shared.summarize(transcript: compressed)
            guard !Task.isCancelled else { return }
            summary = result
            SummaryCache.set(key, mtime: mtime, result)
            summaryBusy = false
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(session.state.color).frame(width: 10, height: 10)
                Text(session.title).font(.headline).lineLimit(2)
                Spacer()
                Button {
                    openWindow(id: "terminal", value: "handoff:\(session.key)")
                } label: {
                    Label("ハンドオフ", systemImage: "arrow.forward.square")
                }
                .controlSize(.small)
                .help("このセッションの要約を初期プロンプトにした新規セッションを開く")
                if let onAttach, session.tmuxSession != nil {
                    Button { onAttach() } label: {
                        Label("ライブattach", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .controlSize(.small)
                    .help("実行中のターミナルへtmuxミラーattach（両側からリアルタイム操作）")
                }
                Button { onClose() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 12) {
                Text(session.agent).font(.subheadline).foregroundStyle(.secondary)
                Text(session.project)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(session.cwd ?? session.project)
                Text("#" + session.sessionId)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .onTapGesture {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(session.sessionId, forType: .string)
                    }
                    .help("クリックでセッションIDをコピー")
                if let branch = session.branch {
                    Text("⎇ \(branch)")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(SessionStore.relativeAge(session.lastActivity))
                    .font(.subheadline).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
    }

    // MARK: history tab (要約+リンク+資料チップ+トランスクリプト)

    private var historyArea: some View {
        VStack(spacing: 0) {
            summarySection
            artifactLinksSection
            linksSection
            Divider()
            turnList
        }
    }

    /// 要約: FM生成(結論優先)。カードの要約表示とも SummaryCache を共有。
    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DisclosureGroup(isExpanded: $summaryExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        if summaryBusy && summary == nil {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("on-device FMで要約を生成中…")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        if let summary {
                            MarkdownView(text: summary)
                        } else if !summaryBusy {
                            Text("要約はまだありません。生成ボタンで作成できます。")
                                .font(.subheadline).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "text.alignleft")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("要約")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                Spacer()
                Button {
                    generateSummary()
                } label: {
                    Label("再生成", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(summaryBusy)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    /// 履歴タブ上部: 資料チップ(クリックで資料タブへ)。圧縮表示で数は抑える。
    private var artifactLinksSection: some View {
        let arts = artifacts.compactMap { p -> Artifact? in
            guard Artifact.kind(for: p) != nil else { return nil }
            return Artifact(path: p)
        }
        return Group {
            if !arts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(arts.prefix(10))) { a in
                            Button {
                                artifactSelection = a.path
                                tab = .artifacts
                            } label: {
                                Label(a.name, systemImage: a.kind?.systemImage ?? "doc")
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(a.path)
                        }
                        if arts.count > 10 {
                            Button {
                                tab = .artifacts
                            } label: {
                                Text("+\(arts.count - 10)件")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .padding(.top, 6)
                .padding(.bottom, 2)
            }
        }
    }

    /// チャット履歴に現れたURLの一覧。クリックで開く(NSDataDetectorで検出)。
    private var linksSection: some View {
        Group {
            if !links.isEmpty {
                DisclosureGroup(isExpanded: $linksExpanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(links, id: \.self) { url in
                            HStack(spacing: 6) {
                                Image(systemName: "link")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text(url)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(Color.accentColor)
                                    .textSelection(.enabled)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                            }
                            .help(url)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "link.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("リンク (\(links.count))")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
            }
        }
    }

    private var turnList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if turns.isEmpty {
                        Text("transcriptが見つかりません")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(turns) { t in
                        turnBubble(t)
                    }
                }
                .padding(14)
            }
            .onAppear {
                if let last = turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func turnBubble(_ t: Turn) -> some View {
        VStack(alignment: t.role == "user" ? .leading : .trailing, spacing: 4) {
            Text(t.role == "user" ? "あなた" : "AI")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(t.role == "user" ? Color.accentColor : .secondary)
            Text(Linkifier.attributed(t.text))
                .font(.body)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(t.role == "user" ? Color.accentColor.opacity(0.12) : Color(white: 0.12))
                )
            // ローカル画像パスは履歴内でインライン表示。クリックで資料タブへ。
            ForEach(LocalImages.inText(t.text), id: \.self) { p in
                HStack {
                    InlineMessageImage(path: p) { _ in
                        artifactSelection = p
                        tab = .artifacts
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Comment goes into the session itself: resume + your text as next turn.
    private var commentBar: some View {
        HStack(spacing: 8) {
            TextField("このセッションにコメント（--resume で次のターンとして送信）…", text: $input)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .onChange(of: inputFocused) { _, f in KeyGate.suppressBoardKeys = f }
                .onSubmit { sendComment() }
            Button(action: sendComment) {
                Image(systemName: "paperplane.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(input.isEmpty)
        }
        .padding(12)
    }

    private func sendComment() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        onClose()
        openWindow(id: "terminal", value: "comment:\(session.key)\n\(text)")
    }

    // MARK: chat tab

    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if messages.isEmpty {
                        Text("このセッションについてAIに質問できます（例: 「何をしていた？」「重要な決定は？」）")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                    ForEach(messages) { m in
                        HStack {
                            if m.role == "user" { Spacer(minLength: 40) }
                            Text(Linkifier.attributed(m.text))
                                .font(.body)
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(m.role == "user" ? Color.accentColor.opacity(0.18) : Color(white: 0.12))
                                )
                            if m.role == "assistant" { Spacer(minLength: 40) }
                        }
                    }
                    if busy {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("on-device FMが回答中…").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(8)
                    }
                }
                .padding(14)
            }
            .onChange(of: messages.count) {
                if let last = messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("質問を入力…", text: $input)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .onChange(of: inputFocused) { _, f in KeyGate.suppressBoardKeys = f }
                .onSubmit { sendQuestion() }
            Button(action: sendQuestion) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(input.isEmpty || busy)
        }
        .padding(12)
    }

    private func sendQuestion() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !busy else { return }
        input = ""
        messages.append(ChatMessage(role: "user", text: question))
        busy = true
        let context = turns.suffix(10).map { "\($0.role == "user" ? "ユーザー" : "AI"): \(String($0.text.prefix(400)))" }
            .joined(separator: "\n")
        let history = messages.map { (role: $0.role, text: $0.text) }
        Task {
            let answer = await FMService.shared.chat(context: context, question: question, history: history)
            messages.append(ChatMessage(role: "assistant", text: answer))
            busy = false
        }
    }
}
