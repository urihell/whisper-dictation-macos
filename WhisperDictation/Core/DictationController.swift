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

    // Held for the whole active session. A `.userInitiated` activity tells macOS
    // not to App-Nap our background menu-bar app while dictating — App Nap
    // throttles timers, which would freeze the live HUD whenever another app
    // takes foreground. Released the moment we return to idle.
    private var dictationActivity: NSObjectProtocol?

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
        // The stream loop failing mid-session (mic open failure, decode error)
        // would otherwise only be logged — leaving a dead "recording" UI with a
        // silent mic. Tear the session down visibly instead.
        transcriber.onStreamError = { [weak self] error in
            guard let self, self.isActive else { return }
            self.fail(error)
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
        // A pending warm-window release is now moot — this session will use (and
        // re-arm) the engine. Cancel it so it can't tear the mic down mid-session.
        cancelWarmRelease()
        // Tell the processor whether to keep the engine warm when this session
        // stops, per the user's setting. (The actual warm engine, if any, is
        // adopted instantly inside start() → startRecordingLive.)
        transcriber.setKeepWarm(AppSettings.shared.micWarmUp != .off)
        // HUD shows "preparing…" immediately for visual feedback, but the audio
        // "go" cue is held until the mic is actually capturing (see below) — on a
        // cold VPIO start the engine takes ~800ms to converge, and chiming "speak
        // now" before then loses the leading word into the dead-zone.
        setState(.preparing)
        OverlayController.shared.show()
        startSessionKeys()
        Task {
            do {
                try await transcriber.start(language: AppSettings.shared.forcedLanguageCode)
                // transcriber.start() only returns once the mic has delivered its
                // first captured buffer (or timed out), so now the "go" cue is
                // honest. If the user already released (push-to-talk) we may have
                // been moved out of .preparing; only advance + chime if still
                // preparing.
                if state == .preparing {
                    SoundFeedback.start()
                    setState(.recording)
                }
                Log.info("begin() — now \(String(describing: state))")
            } catch {
                fail(error)
            }
        }
    }

    /// `pressReturn`: nil → use the global "Press Return after inserting"
    /// setting; otherwise force on/off (used by submit).
    func end(pressReturn: Bool? = nil) async {
        guard state == .preparing || state == .recording else { return }
        // Capture before the .transcribing transition below: a session that
        // reached .recording had the mic live, so an empty result there can mean a
        // dead mic (worth a hint). Ending from .preparing — a fast push-to-talk
        // release — never had a live mic, so it can't and shouldn't warn.
        let wasRecording = state == .recording
        // Only cue "stopped" if "go" ever cued: a fast push-to-talk release can
        // end the session from .preparing — before the start chime played (it
        // waits for the mic to be live) — and a lone stop sound there reads as
        // a glitch.
        if wasRecording { SoundFeedback.stop() }
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

        // Cheap auto-capitalization (no LLM). English-only "i" fix for auto-detect
        // or an explicit English selection.
        if AppSettings.shared.autoCapitalize {
            let lang = AppSettings.shared.forcedLanguageCode
            text = TextFormatter.autoCapitalize(text, english: lang == nil || lang == "en")
        }

        OverlayController.shared.hide()

        guard !text.isEmpty else {
            Log.info("end() — empty transcript, nothing to insert")
            // Distinguish a dead/contended mic (delivered no audio at all) from a
            // genuinely silent session. Only warn when we actually reached
            // .recording — a fast push-to-talk release from .preparing legitimately
            // captures almost nothing and shouldn't read as a mic failure.
            if wasRecording, !transcriber.lastSessionCapturedAudio {
                OverlayController.shared.toast(
                    "🎤 No audio detected — check your microphone"
                )
            } else if wasRecording, transcriber.lastSessionSuppressedNonSpeech {
                // Audio flowed but the detector heard no speech — almost always the
                // wrong input is selected (e.g. AirPods that only picked up music
                // while you spoke at the Mac). Name the mic so the fix is obvious.
                if let mic = transcriber.activeInputDeviceName {
                    OverlayController.shared.toast(
                        "🎤 No speech detected on “\(mic)” — switch your microphone"
                    )
                } else {
                    OverlayController.shared.toast(
                        "🎤 No speech detected — check your microphone selection"
                    )
                }
            }
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
    /// Synchronous on purpose: the transcript is discarded, so there's nothing
    /// to await — `setState(.idle)` routes through `forceStop()`, which tears
    /// the stream down without the final tail re-decode. Moving out of
    /// `.recording` immediately also closes the window where a trigger press
    /// mid-cancel could start a concurrent `end()` and insert cancelled text.
    func cancel() {
        guard state == .preparing || state == .recording else { return }
        Log.info("cancel() — discarding dictation")
        stopSessionKeys()
        OverlayController.shared.hide()
        setState(.idle)
    }

    // MARK: - In-session keys (Escape = cancel, Return = submit in double-tap mode)

    private func startSessionKeys() {
        let tap = SessionKeyTap.shared
        tap.onEscape = { DictationController.shared.cancel() }
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
        if newState == .idle {
            // Stop the recording loop. forceStop() routes through the processor's
            // stopRecording(), which — when warm-up is enabled — keeps the VPIO
            // engine flowing (warm idle) instead of fully releasing the mic, so
            // the next dictation starts instantly. We then arm a timer to release
            // it after the configured window.
            transcriber.forceStop()
            endDictationActivity()
            armWarmReleaseIfNeeded()
        } else {
            beginDictationActivity()
        }
    }

    // MARK: - Microphone warm window

    /// Pending release of the warm mic after the idle window elapses.
    private var warmReleaseTask: Task<Void, Never>?
    /// Watches for OTHER apps grabbing the mic so we release the warm engine early
    /// (e.g. you join a Meet/Zoom call while the mic is still warm).
    private lazy var micUsageMonitor: MicUsageMonitor = {
        let m = MicUsageMonitor()
        m.onOtherProcessStartedInput = { [weak self] in
            // Only release while idle (we're done speaking and not dictating).
            // During a live session this never fires — the monitor isn't running.
            guard let self, self.state == .idle else { return }
            self.releaseWarmMic(reason: "another app started using the mic")
        }
        return m
    }()

    /// After a session ends, release the warm engine when the configured window
    /// elapses — unless another dictation starts first (which cancels this). Also
    /// starts watching for other apps grabbing the mic, to release early.
    /// `.off` releases immediately; `.always` never releases on a timer.
    private func armWarmReleaseIfNeeded() {
        cancelWarmRelease()
        guard transcriber.isMicWarm else { return } // nothing warm (e.g. Bluetooth / off)
        guard let window = AppSettings.shared.micWarmUp.window else {
            // .always — keep warm indefinitely, but still yield to other mic users.
            micUsageMonitor.start()
            return
        }
        guard window > 0 else {
            releaseWarmMic(reason: "warm-up off") // .off — release now
            return
        }
        // Watch for other apps for the whole warm window (between sessions only).
        micUsageMonitor.start()
        let ns = UInt64(window * 1_000_000_000)
        warmReleaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled else { return }
            guard let self, self.state == .idle else { return }
            self.releaseWarmMic(reason: "warm window elapsed")
        }
    }

    /// Cancel a pending warm-release and stop watching for other mic users
    /// (a new session is starting, or we're releasing now).
    private func cancelWarmRelease() {
        warmReleaseTask?.cancel()
        warmReleaseTask = nil
        micUsageMonitor.stop()
    }

    /// Release the warm mic now and tear down the watch. Central path for every
    /// release reason (window elapsed, off, other app, device change, quit).
    private func releaseWarmMic(reason: String) {
        cancelWarmRelease()
        transcriber.releaseWarmMic()
        Log.info("Warm mic released — \(reason).")
    }

    /// Hard-release the warm mic immediately (app background/quit, device change).
    func releaseWarmMicNow() {
        releaseWarmMic(reason: "hard release")
    }

    /// React to a live change of the warm-up setting while a mic is held warm and
    /// no session is active. Off → release now; a bounded window → (re)arm the
    /// timer so the mic doesn't stay on past the newly-chosen window; always →
    /// keep warm (cancel any pending release). Without this, switching e.g.
    /// "Always on" → "30 seconds" would leave the mic warm until the next
    /// dictation. No-op while a session is active (begin/end will re-evaluate).
    func warmUpSettingChanged() {
        guard state == .idle, transcriber.isMicWarm else { return }
        armWarmReleaseIfNeeded()
    }

    /// Begins (once) the App Nap-suppressing activity for the active session.
    private func beginDictationActivity() {
        guard dictationActivity == nil else { return }
        dictationActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated,
            reason: "Live dictation in progress"
        )
    }

    /// Ends the activity assertion when the session returns to idle.
    private func endDictationActivity() {
        guard let activity = dictationActivity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        dictationActivity = nil
    }

    private func fail(_ error: Error) {
        stopSessionKeys()
        transcriber.forceStop()
        OverlayController.shared.hide()
        lastError = error.localizedDescription
        Log.error("Dictation failed: \(error.localizedDescription)")
        OverlayController.shared.toast("⚠️ \(error.localizedDescription)")
        setState(.idle)
    }
}
