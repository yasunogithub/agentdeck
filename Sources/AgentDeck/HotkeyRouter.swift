import Combine
import Foundation
import SwiftUI

/// Single dispatch point for app-level actions, so menu-bar Commands and
/// view-level key handling share one code path (no hidden-button hacks).
enum Hotkey {
    case search
    case openTerminal
    case openDetail
    case handoff
    case toggleHistory
    case rescan
    case moveNext
    case movePrev
    case goFirst
    case goLast
    case rename
    case back
    case focusNext
    case focusPrev
    case archive
    /// ⌘K — Raycast-style command palette overlay.
    case palette
    /// New bare terminal (home dir or picked folder).
    case newTerminal
    /// Sidebar jump keys: 1-6 jump to fixed rows, p cycles projects.
    case sidebarAll
    case sidebarArchive
    case sidebarActive
    case sidebarRunning
    case sidebarWaiting
    case sidebarFailed
    case sidebarDone
    case sidebarIdle
    case cycleProject
    /// ⌘1 — keyboard back to the board from anywhere (esp. the embedded
    /// terminal, which owns every unmodified/⌘-less key while focused).
    case goMain
    /// Trackpad swipe: swipe-left hides the right panel, swipe-right shows
    /// it again (the PTY keeps running underneath, like ←/h toggling).
    case panelHide
    case panelShow
    /// Finder-style type-ahead: a bare printable key that isn't a board
    /// binding appends here; the board narrows its session list by prefix.
    case typeFilter(String)
    /// Reopen a saved standalone terminal window (restore-on-launch).
    case openTerminalSpec(String)
    /// ⌘⇧T — reopen the most recently closed terminal window (browser-style).
    case reopenLastTerminal
}

/// SwiftUI text fields are not detectable via firstResponder class checks,
/// so focus changes publish state here and the key monitor obeys it:
/// bare board keys (return/j/k/h/l/r/arrows) stay out of whichever region
/// is being edited, while Tab keeps cycling regions.
enum KeyGate {
    nonisolated(unsafe) static var suppressBoardKeys = false
    /// Right-panel detail tab is showing: board nav keys and Tab cycling are
    /// disabled so the panel keeps its keys (Return on buttons, Tab moving
    /// between fields) instead of them acting on the board behind it.
    nonisolated(unsafe) static var detailPanelActive = false
}

/// Key-path diagnostics (file-backed; unified log was silent). The keyDown
/// monitor calls write() on every keystroke, so this is OFF by default —
/// even a background open/seek/write/close per key is wasted I/O. Enable with
/// `defaults write agentdeck adDebugLog -bool YES` or AD_DEBUG_LOG=1.
enum DebugLog {
#if DEBUG
    static let enabled = ProcessInfo.processInfo.environment["AD_DEBUG_LOG"] != nil
        || UserDefaults.standard.bool(forKey: "adDebugLog")
#else
    /// Release builds never perform key-path file I/O. Diagnostic logging is
    /// intentionally a debug-only feature so a shipped app cannot persist
    /// typed input (even when a stale UserDefaults flag is present).
    static let enabled = false
#endif
    private static let url = URL(fileURLWithPath: "/tmp/ad-debug.log")
    private static let queue = DispatchQueue(label: "agentdeck.debuglog")
    static func write(_ s: String) {
        guard enabled else { return }
        let line = "\(Date().timeIntervalSince1970) \(s)\n"
        queue.async {
            if let h = FileHandle(forWritingAtPath: url.path) {
                h.seekToEndOfFile()
                h.write(line.data(using: .utf8)!)
                try? h.close()
            } else {
                try? line.data(using: .utf8)?.write(to: url)
            }
        }
    }
}

/// One row in the ⌘K palette. The action closure captures the board, so the
/// palette can reach any app action (open, filter, terminal, rename…).
struct PaletteItem: Identifiable {
    let id = UUID()
    let title: String
    var subtitle = ""
    var icon = "circle"
    var tint: Color = .secondary
    let action: () -> Void
}

final class HotkeyRouter: ObservableObject, @unchecked Sendable {
    static let shared = HotkeyRouter()
    let events = PassthroughSubject<Hotkey, Never>()

    /// Command palette state — driven by the board's key monitor (global keys
    /// while the palette is open) and by PaletteView (typing/hovering).
    @Published var paletteOpen = false
    @Published var paletteQuery = ""
    @Published var paletteSelection = 0
    /// Currently filtered rows; ⏎ runs `paletteItems[paletteSelection]`.
    var paletteItems: [PaletteItem] = []

    /// Menu actions and key handlers both arrive on the main thread.
    func fire(_ h: Hotkey) {
        events.send(h)
    }

    func togglePalette() {
        if paletteOpen { paletteClose() } else { openPalette() }
    }

    func openPalette() {
        paletteQuery = ""
        paletteSelection = 0
        paletteOpen = true
    }

    func paletteClose() {
        paletteOpen = false
    }

    func paletteMove(_ delta: Int) {
        guard !paletteItems.isEmpty else { return }
        paletteSelection = (paletteSelection + delta + paletteItems.count) % paletteItems.count
    }

    func paletteRun() {
        guard !paletteItems.isEmpty else { return }
        let items = paletteItems
        let idx = min(max(paletteSelection, 0), items.count - 1)
        paletteOpen = false
        items[idx].action()
    }
}
