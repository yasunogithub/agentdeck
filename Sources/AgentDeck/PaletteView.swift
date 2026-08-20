import SwiftUI

/// Raycast-style ⌘K overlay: fuzzy filter over actions / sidebar filters /
/// agents / projects / sessions. Esc/↑↓/⏎/⌘K are owned by the board's key
/// monitor, so they keep working regardless of SwiftUI focus.
struct PaletteView: View {
    @ObservedObject private var router = HotkeyRouter.shared
    let items: [PaletteItem]
    @FocusState private var fieldFocused: Bool

    private var filtered: [PaletteItem] {
        let q = router.paletteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.subtitle.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("コマンド・エージェント・プロジェクト・セッションを検索…", text: $router.paletteQuery)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                if !router.paletteQuery.isEmpty {
                    Button {
                        router.paletteQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVStack(spacing: 2) {
                    if filtered.isEmpty {
                        Text("一致する項目がありません")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(16)
                    }
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                        row(item, index: index)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 380)
            Divider()
            HStack {
                Text("↑↓ 移動 · ⏎ 実行 · Esc/⌘K で閉じる")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if !filtered.isEmpty {
                    Text("\(min(router.paletteSelection + 1, filtered.count)) / \(filtered.count)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
        .frame(width: 560)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .onAppear {
            syncFiltered()
            fieldFocused = true
        }
        .onChange(of: router.paletteQuery) { _, _ in syncFiltered() }
    }

    /// Keep the router's item list (what ⏎/the monitor runs) in lockstep with
    /// the filtered rows and clamp the selection into range.
    private func syncFiltered() {
        router.paletteItems = filtered
        if router.paletteSelection >= filtered.count {
            router.paletteSelection = 0
        }
    }

    private func row(_ item: PaletteItem, index: Int) -> some View {
        let selected = index == router.paletteSelection
        return HStack(spacing: 10) {
            Image(systemName: item.icon)
                .frame(width: 18)
                .foregroundStyle(item.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.callout)
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if selected {
                Text("⏎").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.25) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { router.paletteSelection = index }
        }
        .onTapGesture {
            router.paletteOpen = false
            item.action()
        }
    }
}
