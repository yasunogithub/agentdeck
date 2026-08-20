import SwiftUI

/// Turns bare URLs (file://, https://) in plain transcript text into tappable
/// links, so agent-produced report paths open on click instead of being dead text.
enum Linkifier {
    private static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )
    // Body re-evaluates on every throttled store publish (250ms); running
    // NSDataDetector per bubble per render saturated the main thread and
    // made the window flicker. Transcript text is immutable, so memoize.
    // NSLock below guards it; Swift 6.3 flags the global without the marker.
    nonisolated(unsafe) private static var cache: [String: AttributedString] = [:]
    private static let lock = NSLock()

    static func attributed(_ text: String) -> AttributedString {
        lock.lock()
        let hit = cache[text]
        lock.unlock()
        if let hit { return hit }
        let result = detect(text)
        lock.lock()
        if cache.count > 300 { cache.removeAll(keepingCapacity: true) }
        cache[text] = result
        lock.unlock()
        return result
    }

    /// Unique clickable URLs found across transcript text, in first-appearance
    /// order (deduped, capped so a noisy session can't flood the history tab).
    /// The same NSDataDetector powers the attributed bubble links, so what's
    /// listed here is exactly what's tappable in the transcript.
    static func urls(in texts: [String], limit: Int = 30) -> [String] {
        guard let detector else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for text in texts {
            let ns = text as NSString
            let full = NSRange(location: 0, length: ns.length)
            for match in detector.matches(in: text, options: [], range: full) {
                guard let url = match.url?.absoluteString else { continue }
                if seen.insert(url).inserted {
                    out.append(url)
                    if out.count >= limit { return out }
                }
            }
        }
        return out
    }

    private static func detect(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard let detector else { return attributed }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        for match in detector.matches(in: text, options: [], range: full) {
            guard let url = match.url,
                  let range = Range(match.range, in: attributed) else { continue }
            attributed[range].link = url
            attributed[range].foregroundColor = .accentColor
            attributed[range].underlineStyle = Text.LineStyle.single
        }
        return attributed
    }
}

/// Route link clicks (including file://) through NSWorkspace so the default
/// app opens them; SwiftUI's default action is http-only in practice.
struct WorkspaceOpenURL: ViewModifier {
    func body(content: Content) -> some View {
        content.environment(\.openURL, OpenURLAction { url in
            NSWorkspace.shared.open(url)
            return .handled
        })
    }
}

extension View {
    func workspaceOpenURL() -> some View { modifier(WorkspaceOpenURL()) }
}
