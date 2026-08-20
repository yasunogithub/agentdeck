import SwiftUI
import WebKit
import PDFKit
import AppKit

// MARK: - Artifact model

enum ArtifactKind: String, CaseIterable {
    case image
    case html
    case pdf

    var label: String {
        switch self {
        case .image: "画像"
        case .html: "HTML"
        case .pdf: "PDF"
        }
    }

    var systemImage: String {
        switch self {
        case .image: "photo"
        case .html: "doc.richtext"
        case .pdf: "doc.viewfinder"
        }
    }
}

/// A session artifact discoverable in its transcript: local HTML report,
/// image, or PDF.
struct Artifact: Identifiable, Equatable {
    let path: String
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var kind: ArtifactKind? { Artifact.kind(for: path) }

    static func kind(for path: String) -> ArtifactKind? {
        let ext = (path as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(ext) { return .image }
        if ext == "html" || ext == "htm" { return .html }
        if ext == "pdf" { return .pdf }
        return nil
    }
}

/// Local image files for inline rendering in the history panel / card
/// thumbnails. Detects bare absolute paths in plain transcript text.
enum LocalImages {
    private static let pattern = try? NSRegularExpression(
        pattern: "(/[A-Za-z0-9_./@\\-]+\\.(?:png|jpe?g|gif|webp|heic|tiff|bmp))", options: .caseInsensitive)

    /// First `limit` existing local image paths mentioned in a text.
    static func inText(_ text: String, limit: Int = 3) -> [String] {
        guard let pattern, !text.isEmpty else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        var out: [String] = []
        for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var p = ns.substring(with: m.range)
            while let last = p.last, ",\"')]}:;".contains(last) { p.removeLast() }
            guard !seen.contains(p), FileManager.default.fileExists(atPath: p) else { continue }
            seen.insert(p)
            out.append(p)
            if out.count >= limit { break }
        }
        return out
    }
}

/// Small decoded-image cache so grid thumbnails / repeated bubbles don't
/// re-decode the same files on every render.
enum ImageCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var store: [String: NSImage] = [:]

    static func image(_ path: String) -> NSImage? {
        lock.lock()
        let hit = store[path]
        lock.unlock()
        if let hit { return hit }
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        lock.lock()
        if store.count > 200 { store.removeAll(keepingCapacity: true) }
        store[path] = img
        lock.unlock()
        return img
    }

    static func thumbnail(_ path: String, maxSide: CGFloat = 132) -> NSImage? {
        guard let img = image(path) else { return nil }
        let size = img.size
        guard size.width > 0, size.height > 0 else { return img }
        let scale = maxSide / max(size.width, size.height)
        guard scale < 1 else { return img }
        return NSImage(size: NSSize(width: size.width * scale, height: size.height * scale), flipped: false) { rect in
            img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }
}

// MARK: - Browser view

/// In-app browser for a session's artifacts (HTML reports, images, PDFs)
/// with kind filtering, a thumbnail grid, and full previews.
struct ArtifactBrowserView: View {
    let paths: [String]
    /// Selected artifact (bindable so history chips can deep-open it).
    @Binding var selection: String?
    @State private var filter: ArtifactKind? = nil

    private var artifacts: [Artifact] {
        paths.compactMap { path in
            guard Artifact.kind(for: path) != nil else { return nil }
            return Artifact(path: path)
        }
    }

    private var visible: [Artifact] {
        var list = artifacts
        if let filter { list = list.filter { $0.kind == filter } }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            if paths.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    Text("このセッションの資料（HTML・画像・PDF）はまだありません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                filterBar
                Divider()
                if let sel = selection, let art = artifacts.first(where: { $0.path == sel }) {
                    preview(art)
                } else {
                    grid
                }
            }
        }
        .onAppear {
            if selection == nil { selection = paths.first }
        }
        .onChange(of: paths) { _, new in
            if let sel = selection, !new.contains(sel) { selection = new.first }
        }
    }

    // MARK: filter bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterChip("すべて", nil)
                ForEach(ArtifactKind.allCases, id: \.self) { kind in
                    let count = artifacts.filter { $0.kind == kind }.count
                    filterChip("\(kind.label) \(count)", kind)
                }
                Spacer(minLength: 8)
                if let sel = selection {
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: sel))
                    } label: {
                        Label("外部で開く", systemImage: "arrow.up.right.square")
                    }
                    .controlSize(.small)
                    .help("デフォルトアプリで開く")
                } else if let first = visible.first {
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: first.path))
                    } label: {
                        Label("外部で開く", systemImage: "arrow.up.right.square")
                    }
                    .controlSize(.small)
                    .help("デフォルトアプリで開く")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    private func filterChip(_ label: String, _ kind: ArtifactKind?) -> some View {
        Button {
            filter = kind
            if let sel = selection, !visible.contains(where: { $0.path == sel }) {
                selection = visible.first?.path
            }
        } label: {
            Text(label)
                .font(.caption.weight(filter == kind ? .semibold : .regular))
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .tint(filter == kind ? .accentColor : .secondary)
    }

    // MARK: grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108, maximum: 160), spacing: 8)], spacing: 8) {
                ForEach(visible) { art in
                    tile(art)
                }
            }
            .padding(10)
        }
    }

    private func tile(_ art: Artifact) -> some View {
        Button {
            selection = art.path
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if art.kind == .image, let img = ImageCache.thumbnail(art.path) {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 92)
                    } else {
                        Image(systemName: art.kind?.systemImage ?? "doc")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: 92)
                    }
                }
                .frame(height: 92, alignment: .center)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.1)))
                Text(art.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(art.path)
        }
        .buttonStyle(.plain)
    }

    // MARK: preview

    private func preview(_ art: Artifact) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    selection = nil
                } label: {
                    Label("一覧", systemImage: "chevron.left")
                }
                .controlSize(.small)
                Text(art.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(art.path)
                Spacer()
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: art.path))
                } label: {
                    Label("外部で開く", systemImage: "arrow.up.right.square")
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
            Divider()
            previewContent(art)
        }
    }

    @ViewBuilder
    private func previewContent(_ art: Artifact) -> some View {
        switch art.kind {
        case .image:
            if let img = ImageCache.image(art.path) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                }
            } else {
                fallback(art)
            }
        case .html:
            WebKitView(url: URL(fileURLWithPath: art.path))
        case .pdf:
            PDFKitView(url: URL(fileURLWithPath: art.path))
        case nil:
            fallback(art)
        }
    }

    private func fallback(_ art: Artifact) -> some View {
        VStack(spacing: 8) {
            Text("プレビューできない形式です")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("デフォルトアプリで開く") {
                NSWorkspace.shared.open(URL(fileURLWithPath: art.path))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - WebKit / PDFKit representables

struct WebKitView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        context.coordinator.current = url
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.current != url else { return }
        context.coordinator.current = url
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var current: URL?
    }
}

struct PDFKitView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}

/// Inline image shown under a transcript bubble.
struct InlineMessageImage: View {
    let path: String
    var onOpen: (String) -> Void = { _ in }
    @State private var tapped = false

    var body: some View {
        if let img = ImageCache.image(path) {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 340, maxHeight: 160)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.12)))
                .onTapGesture { onOpen(path) }
                .help("クリックで資料タブに開く: \(path)")
        }
    }
}