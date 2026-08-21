import SwiftUI
import AppKit

/// App-wide error reporting. The most recent error wins and is shown as a
/// prominent red banner pinned to the top of EVERY window (board, terminal
/// windows, detail windows) so a failure is never buried in small text.
/// Auto-dismiss after 8s; click × to clear early; a sound plays on post so
/// errors are noticed even while looking at another window.
@MainActor
final class ErrorCenter: ObservableObject {
    static let shared = ErrorCenter()

    struct ErrorItem: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let detail: String?
    }

    @Published var current: ErrorItem?

    /// 未確認エラー数 (post で増え、clear で0に戻る)。バナーは8秒で自動で
    /// 消えるが、赤丸ドットと Dock バッジはユーザーが ×/ドットで確認する
    /// まで残す — 「エラーはめっちゃわかりやすく赤丸とかで」要望の実装。
    @Published private(set) var unacknowledged = 0

    private var dismissTask: Task<Void, Never>?

    func post(_ message: String, detail: String? = nil, playSound: Bool = true) {
        let item = ErrorItem(message: message, detail: detail)
        unacknowledged += 1
        withAnimation(.spring(duration: 0.3)) { current = item }
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            self?.clear()
        }
        if playSound { NSSound(named: "Basso")?.play() }
        updateDockBadge()
    }

    func clear() {
        dismissTask?.cancel()
        dismissTask = nil
        unacknowledged = 0
        withAnimation(.spring(duration: 0.3)) { current = nil }
        updateDockBadge()
    }

    /// Dock アイコンの赤丸バッジ: エラーが残っている間「!」を表示する。
    private func updateDockBadge() {
        NSApp.dockTile.badgeLabel = unacknowledged > 0 ? "!" : nil
    }
}

/// 未処理エラーの赤丸インジケータ。すべての画面の右上に常駐し、バナーが
/// 8秒で消えてもエラーが残っていることを示し続ける。クリックで確認済み
/// (クリア) にする — すぐ隣のバナーの × と同じ意味。
struct ErrorDot: View {
    @ObservedObject private var center = ErrorCenter.shared

    var body: some View {
        if center.unacknowledged > 0, let error = center.current {
            Button {
                center.clear()
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
                        .shadow(color: .red.opacity(0.8), radius: 4)
                    Text("\(center.unacknowledged)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(.red.opacity(0.18)))
                .overlay(Capsule().strokeBorder(.red.opacity(0.55), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("未確認エラー: \(error.message)  (クリックで確認済みにする)")
            .accessibilityIdentifier("errorDot")
            .transition(.scale.combined(with: .opacity))
        }
    }
}

/// Red error banner pinned to the top of a window. Place with
/// `.overlay(alignment: .top) { ErrorBanner() }` on every window root.
struct ErrorBanner: View {
    @ObservedObject private var center = ErrorCenter.shared

    var body: some View {
        if let error = center.current {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.yellow)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(error.message)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                    if let detail = error.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.88))
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    center.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("エラーを閉じる")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.red.opacity(0.92))
                    .shadow(color: .black.opacity(0.4), radius: 14, y: 5)
            )
            .padding(.horizontal, 14)
            .padding(.top, 9)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityIdentifier("errorBanner")
        }
    }
}