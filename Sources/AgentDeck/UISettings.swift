import SwiftUI
import AppKit

/// Persisted UI preferences (UserDefaults — derived, resettable, rot-proof).
final class UISettings: ObservableObject, @unchecked Sendable {
    static let shared = UISettings()

    @Published var sidebarSize: Double {
        didSet { UserDefaults.standard.set(sidebarSize, forKey: "ui.sidebarSize") }
    }
    @Published var boardSize: Double {
        didSet { UserDefaults.standard.set(boardSize, forKey: "ui.boardSize") }
    }
    @Published var designRaw: String {
        didSet { UserDefaults.standard.set(designRaw, forKey: "ui.design") }
    }
    @Published var fontFamily: String {
        didSet { UserDefaults.standard.set(fontFamily, forKey: "ui.fontFamily") }
    }
    @Published var terminalOpacity: Double {
        didSet { UserDefaults.standard.set(terminalOpacity, forKey: "ui.terminalOpacity") }
    }
    /// Main board window translucency: 1.0 = opaque, lower = desktop shows through.
    @Published var mainOpacity: Double {
        didSet { UserDefaults.standard.set(mainOpacity, forKey: "ui.mainOpacity") }
    }
    /// Persisted right-panel width; the drag divider updates it live, so the
    /// panel stays the size you set across sessions.
    @Published var panelWidth: Double {
        didSet { UserDefaults.standard.set(panelWidth, forKey: "ui.panelWidth") }
    }
    /// Persisted sidebar width; the divider between sidebar and board drags it.
    @Published var sidebarWidth: Double {
        didSet { UserDefaults.standard.set(sidebarWidth, forKey: "ui.sidebarWidth") }
    }
    /// Persisted session-card height; dragging a card's bottom edge adjusts it.
    @Published var cardHeight: Double {
        didSet { UserDefaults.standard.set(cardHeight, forKey: "ui.cardHeight") }
    }
    /// Main-board zoom (⌘+/⌘-/⌘0): shifts board font size and card height
    /// together, independently of the terminal zoom.
    @Published var mainZoom: Int {
        didSet { UserDefaults.standard.set(mainZoom, forKey: "ui.mainZoom") }
    }
    /// Terminal zoom (⌘+/⌘-/⌘0 while a terminal holds focus): shifts the
    /// terminal font size only — the board never moves with it.
    @Published var terminalZoom: Int {
        didSet { UserDefaults.standard.set(terminalZoom, forKey: "ui.terminalZoom") }
    }
    /// 完了・アイドルセッションがこの時間(時間)ボードに残ったら自動で
    /// アーカイブへ。0 = オフ。
    @Published var autoArchiveDoneHours: Double {
        didSet { UserDefaults.standard.set(autoArchiveDoneHours, forKey: "ui.autoArchiveDoneHours") }
    }
    /// ターミナルウィンドウ上部ヘッダーのフォントペア: 英字(欧文)用と
    /// 日本語用を別々に指定できる。空 = システム標準。
    @Published var headerLatinFont: String {
        didSet { UserDefaults.standard.set(headerLatinFont, forKey: "ui.headerLatinFont") }
    }
    @Published var headerJapaneseFont: String {
        didSet { UserDefaults.standard.set(headerJapaneseFont, forKey: "ui.headerJapaneseFont") }
    }

    var effectiveBoardSize: Double { min(max(boardSize + Double(mainZoom), 8), 40) }
    /// Card height follows the zoom so a zoomed board reads denser/airier as
    /// a unit; the drag-grip still tunes the base height.
    var effectiveCardHeight: Double { min(max(cardHeight + Double(mainZoom) * 6, 44), 200) }
    /// Terminal font: 15pt base (the pre-zoom default), shifted by ⌘+/-.
    var effectiveTerminalFontSize: Double { min(max(15 + Double(terminalZoom), 9), 34) }
    var autoArchiveEnabled: Bool { autoArchiveDoneHours > 0 }

    /// Font for one terminal pane: the settings baseline (terminalZoom) plus
    /// that pane's own ⌘+/- level (PaneZoom). Panes are independent, so
    /// zooming the right panel never moves a terminal window and vice versa.
    func terminalFont(paneZoom: Int) -> NSFont {
        let family = fontFamily.isEmpty ? "Menlo" : fontFamily
        let size = min(max(15 + Double(terminalZoom) + Double(paneZoom), 9), 34)
        return NSFont(name: family, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func zoomMain(_ delta: Int) { mainZoom = min(max(mainZoom + delta, -4), 8) }
    func zoomTerminal(_ delta: Int) { terminalZoom = min(max(terminalZoom + delta, -6), 10) }

    var design: Font.Design {
        switch designRaw {
        case "rounded": .rounded
        case "serif": .serif
        case "monospaced": .monospaced
        default: .default
        }
    }

    /// Returns a font using the custom fontFamily when set, otherwise system font.
    func customFont(size: Double, weight: Font.Weight = .regular, design: Font.Design? = nil) -> Font {
        let d = design ?? self.design
        if fontFamily.isEmpty {
            return .system(size: size, weight: weight, design: d)
        }
        return Font.custom(fontFamily, size: size).weight(weight)
    }

    /// 「英語はこれ、日本語はこれ」のフォントペア (headerLatinFont /
    /// headerJapaneseFont) を適用した AttributedString。文字列を欧文と
    /// 日本語 (CJK) のランに分け、それぞれ指定ファミリーで描画する。
    /// どちらかが空欄なら該当スクリプトは customFont のシステム標準。
    func headerFont(_ text: String, size: Double, weight: Font.Weight = .regular,
                    design: Font.Design? = nil) -> AttributedString {
        var out = AttributedString()
        var idx = text.startIndex
        while idx < text.endIndex {
            let ch = text[idx]
            let cjk = Self.isCJK(ch)
            var end = text.index(after: idx)
            while end < text.endIndex && Self.isCJK(text[end]) == cjk {
                end = text.index(after: end)
            }
            var part = AttributedString(String(text[idx..<end]))
            let family = cjk ? headerJapaneseFont : headerLatinFont
            if family.isEmpty {
                part.font = customFont(size: size, weight: weight, design: design)
            } else {
                part.font = Font.custom(family, size: size).weight(weight)
            }
            out += part
            idx = end
        }
        return out
    }

    /// True for CJK glyphs (hiragana, katakana, kanji, hangul, full-width,
    /// CJK punctuation) — these get headerJapaneseFont; everything else
    /// (ASCII, Latin-1, emoji, symbols…) uses headerLatinFont.
    static func isCJK(_ ch: Character) -> Bool {
        guard let s = ch.unicodeScalars.first else { return false }
        guard !s.isASCII else { return false }
        let v = s.value
        return (0x3000...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v)
            || (0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0xAC00...0xD7AF).contains(v)
            || (0xFF00...0xFFEF).contains(v)
    }

    private init() {
        let d = UserDefaults.standard
        sidebarSize = d.object(forKey: "ui.sidebarSize") as? Double ?? 13
        boardSize = d.object(forKey: "ui.boardSize") as? Double ?? 14
        designRaw = d.string(forKey: "ui.design") ?? "default"
        fontFamily = d.string(forKey: "ui.fontFamily") ?? ""
        terminalOpacity = d.object(forKey: "ui.terminalOpacity") as? Double ?? 1.0
        mainOpacity = d.object(forKey: "ui.mainOpacity") as? Double ?? 1.0
        panelWidth = min(max(d.object(forKey: "ui.panelWidth") as? Double ?? 520, 280), 760)
        sidebarWidth = min(max(d.object(forKey: "ui.sidebarWidth") as? Double ?? 210, 160), 420)
        cardHeight = min(max(d.object(forKey: "ui.cardHeight") as? Double ?? 76, 44), 160)
        mainZoom = d.object(forKey: "ui.mainZoom") as? Int ?? 0
        terminalZoom = d.object(forKey: "ui.terminalZoom") as? Int ?? 0
        autoArchiveDoneHours = d.object(forKey: "ui.autoArchiveDoneHours") as? Double ?? 2
        headerLatinFont = d.string(forKey: "ui.headerLatinFont") ?? ""
        headerJapaneseFont = d.string(forKey: "ui.headerJapaneseFont") ?? ""
    }
}

/// Installed system font families for the Settings picker: hidden Apple
/// families (dot-prefixed) and symbol/emoji-only families are filtered out.
enum FontFamilies {
    static let all: [String] = {
        let banned: Set<String> = [
            "Apple Symbols", "Zapf Dingbats", "Noto Color Emoji",
            "Apple Color Emoji", "Arial Unicode MS", "LastResort",
            "Hiragino Maru Gothic ProN", // dup of W4/W8 variants is confusing
        ]
        let families = NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") && !banned.contains($0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return families
    }()
}

/// Applies a translucency to the hosting NSWindow. Re-applies whenever the
/// opacity value changes, so moving the settings slider updates live.
struct WindowTransparencyModifier: ViewModifier {
    let opacity: Double
    @State private var window: NSWindow?

    func body(content: Content) -> some View {
        content
            .background(WindowAccessor { w in
                if window !== w {
                    window = w
                }
                apply()
            })
            .onChange(of: opacity) { _, _ in apply() }
    }

    private func apply() {
        guard let window else { return }
        window.alphaValue = opacity
        window.isOpaque = opacity >= 0.999
    }
}

extension View {
    func windowTransparency(_ opacity: Double) -> some View {
        modifier(WindowTransparencyModifier(opacity: opacity))
    }
}

/// Bridges NSWindow to SwiftUI via an NSView representable.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onWindow(v.window) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}

struct SettingsView: View {
    @ObservedObject private var ui = UISettings.shared

    var body: some View {
        Form {
            Section("フォント") {
                Picker("デザイン", selection: $ui.designRaw) {
                    Text("標準").tag("default")
                    Text("丸ゴシック").tag("rounded")
                    Text("セリフ").tag("serif")
                    Text("等幅").tag("monospaced")
                }
                .pickerStyle(.segmented)

                LabeledContent("ファミリー") {
                    Picker("", selection: $ui.fontFamily) {
                        Text("システム標準").tag("")
                        ForEach(FontFamilies.all, id: \.self) { family in
                            Text(family).tag(family)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                .help("インストール済みフォントから選択。空欄=システムフォント+デザイン設定")

                LabeledContent("サイドメニュー \(Int(ui.sidebarSize))") {
                    Slider(value: $ui.sidebarSize, in: 11...18, step: 1)
                }
                LabeledContent("本体 \(Int(ui.boardSize))") {
                    Slider(value: $ui.boardSize, in: 12...20, step: 1)
                }
            }
            Section("ターミナル上部フォント") {
                LabeledContent("英字 (ラテン)") {
                    Picker("", selection: $ui.headerLatinFont) {
                        Text("システム標準").tag("")
                        ForEach(FontFamilies.all, id: \.self) { family in
                            Text(family).tag(family)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                .help("ターミナルウィンドウ上部の英字に使うフォント")

                LabeledContent("日本語") {
                    Picker("", selection: $ui.headerJapaneseFont) {
                        Text("システム標準").tag("")
                        ForEach(FontFamilies.all, id: \.self) { family in
                            Text(family).tag(family)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                .help("ターミナルウィンドウ上部の日本語 (かな・漢字) に使うフォント")

                Text(ui.headerFont("PR #3777 merged ・ 引継ぎフローの修正", size: 15, weight: .semibold))
                    .lineLimit(1)
                    .padding(6)
                    .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 6))
                Text("英字と日本語でフォントを分けて指定できます (空欄 = システム標準)。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("ターミナル") {
                LabeledContent("透過 \(Int(ui.terminalOpacity * 100))%") {
                    Slider(value: $ui.terminalOpacity, in: 0.3...1.0, step: 0.05)
                }
                Text("低いほどデスクトップが透けて見えます。次に開くターミナルウィンドウから適用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("本体") {
                LabeledContent("透過 \(Int(ui.mainOpacity * 100))%") {
                    Slider(value: $ui.mainOpacity, in: 0.3...1.0, step: 0.05)
                }
                Text("セッションを選択してEnterで右パネルを開きます（⌘Kでコマンドパレット、⌘⌘で音声入力）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("右パネル") {
                LabeledContent("幅 \(Int(ui.panelWidth))") {
                    Slider(value: $ui.panelWidth, in: 280...760, step: 10)
                }
                Text("ヘッダー右端のドラッグでも調整できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("レイアウト") {
                LabeledContent("サイドバー幅 \(Int(ui.sidebarWidth))") {
                    Slider(value: $ui.sidebarWidth, in: 160...420, step: 10)
                }
                LabeledContent("カード高さ \(Int(ui.cardHeight))") {
                    Slider(value: $ui.cardHeight, in: 44...160, step: 4)
                }
                Text("サイドバー右端とカード下端をドラッグしても調整できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("ズーム (⌘+/⌘-/⌘0)") {
                LabeledContent("Main") {
                    HStack(spacing: 8) {
                        Text("フォント \(Int(ui.effectiveBoardSize))pt ・ カード \(Int(ui.effectiveCardHeight))pt")
                            .font(.caption).foregroundStyle(.secondary)
                        Button {
                            ui.zoomMain(-1)
                        } label: { Image(systemName: "minus.magnifyingglass") }
                        Button {
                            ui.zoomMain(1)
                        } label: { Image(systemName: "plus.magnifyingglass") }
                        Button("リセット") { ui.zoomMain(-ui.mainZoom) }
                            .disabled(ui.mainZoom == 0)
                    }
                }
                LabeledContent("ターミナル") {
                    HStack(spacing: 8) {
                        Text("フォント \(Int(ui.effectiveTerminalFontSize))pt")
                            .font(.caption).foregroundStyle(.secondary)
                        Button {
                            ui.zoomTerminal(-1)
                        } label: { Image(systemName: "minus.magnifyingglass") }
                        Button {
                            ui.zoomTerminal(1)
                        } label: { Image(systemName: "plus.magnifyingglass") }
                        Button("リセット") { ui.zoomTerminal(-ui.terminalZoom) }
                            .disabled(ui.terminalZoom == 0)
                    }
                }
                Text("Mainとターミナルは独立して拡縮されます。ターミナルは ⌘+/- でフォーカスのある Pane だけ拡縮、⌘0 でその Pane をリセット (ここは全 Pane 共通の基準)。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("自動アーカイブ") {
                Toggle("完了・アイドルを自動でアーカイブ", isOn: Binding(
                    get: { ui.autoArchiveEnabled },
                    set: { ui.autoArchiveDoneHours = $0 ? 2 : 0 }
                ))
                if ui.autoArchiveEnabled {
                    LabeledContent("ボードに残す時間 \(Int(ui.autoArchiveDoneHours)) 時間") {
                        Slider(value: $ui.autoArchiveDoneHours, in: 1...12, step: 1)
                    }
                }
                Text("完了/アイドルになってから設定時間が経過するとサイドバーのアーカイブへ自動で移動します（ボードが雑多になるのを防ぎます）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("プレビュー") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("サイドメニュー: em-roadster-3 ・ 実行中")
                        .font(ui.customFont(size: ui.sidebarSize))
                    Text("Partner登録フローの修正")
                        .font(ui.customFont(size: ui.boardSize, weight: .medium))
                    Text("→ PR #3777 をマージ済み。次のステップを提案中。")
                        .font(ui.customFont(size: ui.boardSize - 4))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("通知") {
                NotificationSettingsSection()
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 620)
    }
}

/// 通知のイベント別 ON/OFF・サウンド・静寂時間の設定。
/// NotificationSettings はロックで守られた prefs を持つので、表示は
/// revision を観察し、変更は update() 経由で反映する。
struct NotificationSettingsSection: View {
    @ObservedObject private var settings = NotificationSettings.shared

    /// revision 変化を body 再評価に変換しつつ、現在値を束ねた Binding を作る。
    private func bind<V: Equatable>(_ get: @escaping (NotificationPrefs) -> V,
                                    _ set: @escaping (inout NotificationPrefs, V) -> Void)
        -> Binding<V> {
        Binding(
            get: { get(NotificationSettings.shared.prefs) },
            set: { newValue in
                NotificationSettings.shared.update { p in set(&p, newValue) }
            }
        )
    }

    var body: some View {
        let prefs = NotificationSettings.shared.prefs
        ForEach(NotificationEvent.allCases) { ev in
            HStack {
                Toggle(ev.label, isOn: bind({ $0.isEnabled(ev) }, { $0.enabled[ev.rawValue] = $1 }))
                Spacer()
                Picker("", selection: bind({ $0.sound(for: ev) }, { $0.sounds[ev.rawValue] = $1 })) {
                    Text("無音").tag("")
                    ForEach(NotificationSettings.soundChoices.filter { !$0.isEmpty }, id: \.self) { s in
                        Text(s).tag(s)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                .disabled(!prefs.isEnabled(ev))
            }
        }
        Divider()
        Toggle("静寂時間", isOn: bind({ $0.quietEnabled }, { $0.quietEnabled = $1 }))
        if prefs.quietEnabled {
            HStack {
                LabeledContent("開始") {
                    Picker("", selection: bind({ $0.quietStartHour }, { $0.quietStartHour = $1 })) {
                        ForEach(0..<24) { h in Text("\(h):00").tag(h) }
                    }
                    .labelsHidden().frame(width: 90)
                }
                LabeledContent("終了") {
                    Picker("", selection: bind({ $0.quietEndHour }, { $0.quietEndHour = $1 })) {
                        ForEach(0..<24) { h in Text("\(h):00").tag(h) }
                    }
                    .labelsHidden().frame(width: 90)
                }
            }
        }
        Text("静寂時間中はセッション通知を止めます (音声入力など操作フィードバックは鳴り続けます)。通知をクリックするとそのセッションを開きます。")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
