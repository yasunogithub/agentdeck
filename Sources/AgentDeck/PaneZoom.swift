import Foundation
import AppKit
import SwiftTerm

/// Per-pane terminal font zoom. Every pane — the board's right-panel
/// terminal and each standalone terminal window — keeps its own ⌘+/⌘−/⌘0
/// level, so resizing one pane never moves the others. Levels are per
/// window/panel identity (not persisted): restored windows re-open at the
/// settings baseline, which is the expected "new pane" behavior.
final class PaneZoom: @unchecked Sendable {
    static let shared = PaneZoom()

    private var zoomByPane: [String: Int] = [:]
    private let lock = NSLock()

    func zoom(_ paneID: String) -> Int { lock.withLock { zoomByPane[paneID] ?? 0 } }

    func adjust(_ paneID: String, by delta: Int) {
        lock.withLock { zoomByPane[paneID] = min(max((zoomByPane[paneID] ?? 0) + delta, -6), 10) }
    }

    func reset(_ paneID: String) { lock.withLock { zoomByPane[paneID] = 0 } }

    /// Which pane a terminal view belongs to: the board's right panel is a
    /// single shared pane; each standalone terminal window is its own pane
    /// (windowNumber-based, so every new/restored window starts at the
    /// baseline). "window:pre" is the short moment before a view joins its
    /// window — applyFont re-runs after attach, so it never sticks.
    static func paneID(for view: LocalProcessTerminalView) -> String {
        if (view as? TranslucentTerminalView)?.embedded == true { return "panel:right" }
        if let w = view.window { return "window:\(w.windowNumber)" }
        return "window:pre"
    }
}