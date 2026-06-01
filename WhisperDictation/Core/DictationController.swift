import Foundation
import Combine
import AppKit

enum DictationState {
    case idle
    case preparing   // loading model / starting the stream
    case recording   // streaming live transcription
    case transcribing // finalizing after stop
    case cleaning    // on-device LLM cleanup
    case inserting
}

/// Orchestrates a dictation session: show HUD → stream live → insert final
/// text at the cursor on stop. Publishes state for the menu bar and HUD.
@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()

    @Published private(set) var state: DictationState = .idle
    @Published var lastError: String?

    let transcriber = StreamingTranscriber()
    private let inserter = TextInserter()

    // Suppresses the "switched" toast for the very first model load at launch.
    private var announcedFirstModel = false

    private init() {
        transcriber.onModelReady = { [weak self] modelName in
            guard let self else { return }
            if self.announcedFirstModel {
                OverlayController.shared.toast("Switched to \(Self.friendlyModelName(modelName))")
            }
            self.announcedFirstModel = true
        }
        transcriber.onModelLoadFailed = { modelName in
            OverlayController.shared.toast(
                "⚠️ Couldn't load \(Self.friendlyModelName(modelName)) — check your internet connection"
            )
        }
    }

    /// Loads the configured model in the background so it's ready (or compiling)
    /// before the first dictation. Call once at launch.
    func preloadModel() {
        transcriber.requestModel(AppSettings.shared.modelName)
    }

    static func friendlyModelName(_ id: String) -> String {
        switch id {
        case "openai_whisper-tiny": return "Tiny"
        case "openai_whisper-base": return "Base"
        case "openai_whisper-small": return "Small"
        case "openai_whisper-medium": return "Medium"
        case "openai_whisper-large-v3-v20240930_turbo_632MB": return "Large v3 Turbo"
        case "openai_whisper-large-v3": return "Large v3"
        default: return id
        }
    }

    var isActive: Bool { state != .idle }

    // Trigger gesture handling (shared by the key-combo and single-key paths).
    private static let doubleTapWindow: TimeInterval = 0.3
    private var lastTriggerDownTime: Date?

    /// Start if idle, finish if live. Used by the menu and the trigger handlers.
    func toggle() {
        switch state {
        case .idle:
            begin()
        case .recording:
            Task { await end() }
        case .preparing, .transcribing, .cleaning, .inserting:
            break // busy — ignore
        }
    }

    /// The trigger key/shortcut was pressed.
    ///   - double-tap ON: a double-tap starts dictation; a single tap submits
    ///     (stops + inserts) while running. A lone single tap when idle does
    ///     nothing — it takes a double-tap to begin.
    ///   - double-tap OFF: single press toggles (or, in push-to-talk, starts and
    ///     the release stops); a double-tap is just two ordinary presses.
    func triggerDown() {
        if AppSettings.shared.doubleTapEnabled {
            switch state {
            case .recording:
                submit()                    // single tap submits while running
            case .idle:
                let now = Date()
                let isDoubleTap = lastTriggerDownTime
                    .map { now.timeIntervalSince($0) <= Self.doubleTapWindow } ?? false
                if isDoubleTap {
                    lastTriggerDownTime = nil   // consume the pair
                    begin()
                } else {
                    lastTriggerDownTime = now
                }
            case .preparing, .transcribing, .cleaning, .inserting:
                break // busy — ignore
            }
            return
        }

        switch AppSettings.shared.triggerMode {
        case .toggle:
            toggle()
        case .pushToTalk:
            if state == .idle { begin() }
        }
    }

    /// Stop dictation and insert (used by the single-tap / Enter submit in
    /// double-tap mode). Presses Return too when "submit sends" is on.
    func submit() {
        guard state == .recording || state == .preparing else { return }
        Task { await end(pressReturn: AppSettings.shared.submitSendsReturn) }
    }

    /// The trigger key/shortcut was released.
    func triggerUp() {
        // In double-tap mode, holds/releases do nothing.
        guard !AppSettings.shared.doubleTapEnabled else { return }
        guard AppSettings.shared.triggerMode == .pushToTalk else { return }
        guard state == .recording || state == .preparing else { return }
        Task { await end() }
    }

    func begin() {
        guard state == .idle else { return }
        Log.info("begin() — preparing")
        setState(.preparing)
        OverlayController.shared.show()
        startSessionKeys()
        Task {
            do {
                try await transcriber.start(language: AppSettings.shared.forcedLanguageCode)
                // If the user already released (push-to-talk) we may have been
                // moved out of .preparing; only advance if still preparing.
                if state == .preparing { setState(.recording) }
                Log.info("begin() — now \(String(describing: state))")
            } catch {
                OverlayController.shared.hide()
                fail(error)
            }
        }
    }

    /// `pressReturn`: nil → use the global "Press Return after inserting"
    /// setting; otherwise force on/off (used by submit).
    func end(pressReturn: Bool? = nil) async {
        guard state == .preparing || state == .recording else { return }
        stopSessionKeys()

        setState(.transcribing)
        var text = await transcriber.stop()
        // Log only the length — never the dictated content. The transcript can
        // contain passwords, 2FA codes, or private messages, and the unified log
        // is persisted and readable via Console/sysdiagnose.
        Log.info("end() — raw transcript: \(text.count) chars")

        // Optional on-device cleanup (remove self-corrections + filler).
        if AppSettings.shared.cleanupEnabled, SpeechCleaner.isAvailable, !text.isEmpty {
            setState(.cleaning)
            text = await SpeechCleaner.clean(text, languageHint: AppSettings.shared.forcedLanguageCode)
        }

        // Voice formatting commands ("new line" / "new paragraph") — applied last
        // so they operate on the final text that gets typed.
        if AppSettings.shared.voiceCommandsEnabled {
            text = VoiceCommands.apply(text)
        }

        OverlayController.shared.hide()

        guard !text.isEmpty else {
            Log.info("end() — empty transcript, nothing to insert")
            setState(.idle)
            return
        }

        setState(.inserting)
        inserter.insert(
            text,
            directType: AppSettings.shared.directTyping,
            restoreClipboard: AppSettings.shared.restoreClipboard,
            pressReturn: pressReturn ?? AppSettings.shared.pressReturnAfterInsert
        )
        setState(.idle)
    }

    /// Aborts the current session and discards the transcript (Escape).
    func cancel() async {
        guard state == .preparing || state == .recording else { return }
        Log.info("cancel() — discarding dictation")
        stopSessionKeys()
        _ = await transcriber.stop()
        OverlayController.shared.hide()
        setState(.idle)
    }

    // MARK: - In-session keys (Escape = cancel, Return = submit in double-tap mode)

    private func startSessionKeys() {
        let tap = SessionKeyTap.shared
        tap.onEscape = { Task { await DictationController.shared.cancel() } }
        tap.shouldHandleReturn = { AppSettings.shared.doubleTapEnabled }
        tap.onReturn = { DictationController.shared.submit() }
        tap.start()
    }

    private func stopSessionKeys() {
        SessionKeyTap.shared.stop()
    }

    private func setState(_ newState: DictationState) {
        state = newState
        StatusController.shared.state = newState
        // Backstop: whenever we're idle, guarantee the mic is released — no
        // orphaned recording loop can keep it open after a session ends.
        if newState == .idle { transcriber.forceStop() }
    }

    private func fail(_ error: Error) {
        stopSessionKeys()
        transcriber.forceStop()
        lastError = error.localizedDescription
        Log.error("Dictation failed: \(error.localizedDescription)")
        OverlayController.shared.toast("⚠️ \(error.localizedDescription)")
        setState(.idle)
    }
}
