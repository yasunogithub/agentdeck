import SwiftUI
import Foundation

/// Minimal-but-good Markdown renderer for AgentDeck content (handoff briefs,
/// on-device FM summaries, vault digests). Block-level: ATX headings, fenced
/// code, bullet/numbered lists, blockquotes, horizontal rules, paragraphs.
/// Inline: **bold**, *italic*, `code`, [links](url) plus bare http(s)/file://
/// URLs (tappable, opened via NSWorkspace). A leading 「結論:」 paragraph is
/// highlighted so FM summaries keep their conclusion-first emphasis.
struct MarkdownView: View {
    let text: String
    var baseFont = Font.body

    private enum Block {
        case heading(level: Int, text: String)
        case code(String)
        case bullet(String)
        case number(Int, String)
        case quote(String)
        case rule
        case paragraph(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func render(_ b: Block) -> some View {
        switch b {
        case .heading(let level, let t):
            inline(t)
                .font(.system(size: Self.headingSize(level), weight: .semibold))
                .padding(.top, level <= 2 ? 6 : 2)
        case .code(let code):
            Text(code)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.09)))
        case .bullet(let t):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                inline(t)
            }
        case .number(let n, let t):
            HStack(alignment: .top, spacing: 6) {
                Text("\(n).").foregroundStyle(.secondary)
                inline(t)
            }
        case .quote(let t):
            inline(t)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 2)
                }
        case .rule:
            Divider()
        case .paragraph(let t):
            if t.hasPrefix("結論:") || t.hasPrefix("結論：") {
                inline(t)
                    .font(baseFont.weight(.semibold))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
            } else {
                inline(t).font(baseFont)
            }
        }
    }

    private func inline(_ s: String) -> Text {
        var attr = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
        Self.detectLinks(&attr)
        return Text(attr)
    }

    /// Bare URLs (http/https/file) → link + accent, so they open on click
    /// through the view's WorkspaceOpenURL action (NSWorkspace).
    private static func detectLinks(_ attr: inout AttributedString) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        let text = String(attr.characters)
        let ns = text as NSString
        for match in detector.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url,
                  let range = Range(match.range, in: attr) else { continue }
            attr[range].link = url
            attr[range].foregroundColor = .accentColor
            attr[range].underlineStyle = Text.LineStyle.single
        }
    }

    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 22
        case 2: 18
        case 3: 16
        default: 14
        }
    }

    private static func parse(_ text: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        func flush() {
            if !para.isEmpty {
                out.append(.paragraph(para.joined(separator: "\n")))
                para = []
            }
        }
        let lines = text.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                var code: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                out.append(.code(code.joined(separator: "\n")))
                continue
            }
            if trimmed.isEmpty { flush(); i += 1; continue }
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                if level <= 6 {
                    flush()
                    let rest = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
                    if !rest.isEmpty { out.append(.heading(level: level, text: rest)) }
                    i += 1
                    continue
                }
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flush()
                out.append(.rule)
                i += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                out.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                i += 1
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flush()
                out.append(.bullet(String(trimmed.dropFirst(2))))
                i += 1
                continue
            }
            if let m = trimmed.firstMatch(of: /^(\d{1,3})[\.\)]\s+(.*)$/) {
                flush()
                out.append(.number(Int(m.1) ?? 1, String(m.2)))
                i += 1
                continue
            }
            para.append(line)
            i += 1
        }
        flush()
        return out
    }
}
