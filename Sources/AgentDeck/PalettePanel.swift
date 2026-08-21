import AppKit
import SwiftUI
import Combine

/// ⌘K パレットを表示するスポットライト式フローティングパネル。
///
/// これまで各ウィンドウの overlay に PaletteView をホストしていたが、
/// - 入力フォーカスが SwiftUI FocusState に依存して外れることがある
/// - 表示元ウィンドウごとに項目配列を再構築して重かった
/// ので、独立パネルに集約した。パネル自身がキーになるので TextField への
/// フォーカスが確実で、どの窓から開いても同じ見た目・同じ速度で出る。
@MainActor
final class PalettePanelController: NSObject, @unchecked Sendable {
    static let shared = PalettePanelController()

    private var panel: PalettePanel?
    private var cancellable: AnyCancellable?

    /// AppDelegate 起動時に呼ぶ。paletteOpen の変化を監視して表示切替。
    func start() {
        cancellable = HotkeyRouter.shared.$paletteOpen
            .receive(on: DispatchQueue.main)
            .sink { [weak self] open in
                MainActor.assumeIsolated {
                    if open { self?.show() } else { self?.hide() }
                }
            }
        // フォーカスが外れたら閉じる (selector 方式: Sendable 制約を回避)
        NotificationCenter.default.addObserver(
            self, selector: #selector(onResignKey(_:)),
            name: NSWindow.didResignKeyNotification, object: nil
        )
    }

    @objc private func onResignKey(_ note: Notification) {
        guard (note.object as? NSWindow) === panel else { return }
        HotkeyRouter.shared.paletteClose()
    }

    private func show() {
        if panel == nil {
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let size = NSSize(width: 600, height: 480)
            let rect = NSRect(
                x: screen.midX - size.width / 2,
                y: screen.maxY - size.height - 120,
                width: size.width,
                height: size.height
            )
            let p = PalettePanel(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView:
                PaletteView(items: GlobalPaletteCatalog.items())
                    .frame(width: size.width, height: size.height)
            )
            panel = p
        }
        guard let p = panel else { return }
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        p.makeKey()
        // FocusState の他、AppKit 側でも確実にフィールドへフォーカスする
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, let p = self.panel, p.isKeyWindow else { return }
            if !(p.firstResponder is NSTextView), let field = Self.findTextField(in: p.contentView) {
                p.makeFirstResponder(field)
            }
        }
    }

    private func hide() {
        guard let p = panel else { return }
        panel = nil
        p.orderOut(nil)
    }

    /// フォーカス外れ (他アプリ/窓をクリック) で閉じる。

    private static func findTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let tf = view as? NSTextField { return tf }
        for sub in view.subviews {
            if let found = findTextField(in: sub) { return found }
        }
        return nil
    }
}

/// borderless パネルはデフォルトでキーになれないためオーバーライドする。
final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
