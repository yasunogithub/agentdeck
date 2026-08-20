import AppKit
import AVFoundation
import Foundation
import Speech

/// Double-⌘ voice dictation using the system Speech framework (Apple's
/// built-in recognizer, no third-party SDK). Result is always copied to the
/// clipboard and, when a terminal has focus, typed straight into it.
final class DictationService: ObservableObject, @unchecked Sendable {
    static let shared = DictationService()

    @Published var active = false
    @Published var interim = ""

    private var box: MicBox?

    /// The audio tap fires on a realtime thread while stop() runs on main —
    /// this box is the @unchecked Sendable hand-off for the live objects.
    private final class MicBox: @unchecked Sendable {
        var engine: AVAudioEngine?
        var request: SFSpeechAudioBufferRecognitionRequest?
        var task: SFSpeechRecognitionTask?
    }

    /// Called from the key monitor (or anywhere) — hops to the main actor.
    func toggle() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { active ? finish() : start() }
        } else {
            DispatchQueue.main.async { DictationService.shared.toggle() }
        }
    }

    @MainActor
    private func start() {
        guard !active else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in self?.authorized(status) }
        }
    }

    @MainActor
    private func authorized(_ status: SFSpeechRecognizerAuthorizationStatus) {
        guard status == .authorized else {
            Notifier.shared.notify(title: "音声入力", body: "システム設定でマイクと音声認識の許可が必要です", sound: "Funk")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP")), recognizer.isAvailable else {
            Notifier.shared.notify(title: "音声入力", body: "音声認識が利用できません", sound: "Funk")
            return
        }

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        let box = MicBox()
        box.engine = engine
        box.request = request
        box.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Pass only Sendable values across; the actor hop happens on task.
            let text = result?.bestTranscription.formattedString
            let failed = error != nil
            Task { @MainActor in
                guard let self else { return }
                if let text {
                    self.interim = text
                }
                if failed {
                    self.finish()
                }
            }
        }
        self.box = box

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            box.request?.append(buffer)
        }
        engine.prepare()
        try? engine.start()

        active = true
        interim = ""
        Notifier.shared.notify(title: "音声入力中", body: "話してください — 確定は ⌘ をもう2回", sound: nil)
    }

    /// Called from the monitor on a second ⌘-tap, or on recognition end.
    func stop() {
        toggle()
    }

    @MainActor
    private func finish() {
        let text = interim.trimmingCharacters(in: .whitespacesAndNewlines)
        if let b = box {
            b.task?.cancel()
            b.request?.endAudio()
            b.engine?.stop()
            b.engine?.inputNode.removeTap(onBus: 0)
        }
        box = nil
        active = false
        interim = ""
        guard !text.isEmpty else { return }

        // Always copy; insert into the focused terminal when there is one.
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        if let terminal = NSApp.keyWindow?.firstResponder as? TranslucentTerminalView {
            terminal.send(txt: text)
            Notifier.shared.notify(title: "音声を挿入しました", body: String(text.prefix(40)), sound: "Glass")
        } else {
            Notifier.shared.notify(title: "音声テキストをコピーしました", body: String(text.prefix(40)), sound: "Glass")
        }
    }
}