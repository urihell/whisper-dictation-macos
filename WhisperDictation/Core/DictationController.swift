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
    // Streaming cleanup text lives in HUDLiveState (token-rate updates must
    // not fire this object's objectWillChange — the menu bar dropdown observes
    // this controller, and its view graph tears down on every close; see
    // HUDLiveState's doc comment for the teardown-race rationale).
    /// The most recent final transcript — a recovery net for when insertion
    /// lands in the wrong window or an app silently drops synthetic input.
    /// MEMORY ONLY, never persisted or logged: it can contain passwords, 2FA
    /// codes, or private messages. Surfaced via menu → "Copy Last Transcript".
    @Published private(set) var lastTranscript: String?

    /// When set, the active session is CAPTURE-ONLY (Shortcuts "Dictate Text"):
    /// the final transcript is delivered here instead of being typed at the
    /// cursor. Resolved exactly once — on end (with the text), or on
    /// cancel/failure (with "") so the awaiting intent can never hang.
    private var captureCompletion: ((String) -> Void)?

    /// Runs one dictation session and returns the transcript WITHOUT typing
    /// it (Shortcuts pipelines). The session behaves normally — HUD, hotkey
    /// stop, Escape cancel — it just diverts the result. Returns "" if a
    /// session is already active, or on cancel/failure.
    func dictateAndReturn() async -> String {
        guard state == .idle, captureCompletion == nil else { return "" }
        return await withCheckedContinuation { continuation in
            captureCompletion = { text in continuation.resume(returning: text) }
            begin()
        }
    }

    /// Resolves a pending capture-only session, if any. Returns true when the
    /// session was capture-only (the caller should skip insertion).
    private func resolveCapture(with text: String) -> Bool {
        guard let capture = captureCompletion else { return false }
        captureCompletion = nil
        capture(text)
        return true
    }

    let transcriber = StreamingTranscriber()
    private let inserter = TextInserter()

    /// The engine driving the CURRENT session (chosen at begin() from the
    /// engine setting; may fall back to Whisper mid-begin for an unsupported
    /// language). All session teardown paths must go through this reference —
    /// stopping the wrong engine would leave a live mic.
    private var sessionEngine: (any DictationEngine)?
    /// Which engine kind the current session runs on — drives the HUD's engine
    /// badge so a silent fallback to Whisper is visible. Nil when idle.
    @Published private(set) var sessionEngineKind: TranscriptionEngine?
    /// The current session's effective language (nil = auto-detect), after
    /// applying any per-app override. Captured at begin() and used everywhere
    /// downstream (engine start, cleanup hint, auto-capitalization) so the
    /// whole session agrees on one language.
    private var sessionLanguageCode: String?

    /// Lazily-built Apple Speech engine (macOS 26+). Stored type-erased so the
    /// property itself needs no availability annotation.
    private var appleEngineStorage: AnyObject?
    @available(macOS 26.0, *)
    private var appleEngine: AppleSpeechEngine {
        if let engine = appleEngineStorage as? AppleSpeechEngine { return engine }
        let engine = AppleSpeechEngine()
        engine.onStreamError = { [weak self] error in
            guard let self, self.isActive else { return }
            self.fail(error)
        }
        appleEngineStorage = engine
        return engine
    }

    /// Engine for a NEW session per the setting and the session's effective
    /// language. Auto-detect ALWAYS routes to Whisper: Apple's transcriber is
    /// single-language per session, so under "auto" it would silently pin to
    /// the system language and mangle anything else (observed: Hebrew dictated
    /// into an English-locked session).
    private func selectEngine(languageCode: String?) -> any DictationEngine {
        if #available(macOS 26.0, *),
           AppSettings.shared.transcriptionEngine == .apple {
            if languageCode != nil {
                return appleEngine
            }
            Log.info("Language is auto-detect — using Whisper (Apple Speech needs a fixed language).")
        }
        return transcriber
    }
    /// Cleans confirmed sentences in the background while the user speaks, so
    /// stopping only waits on the last sentence or two. Created per session
    /// when cleanup is enabled; consumed (or cancelled) when it ends.
    private var incrementalCleaner: IncrementalCleaner?

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
    /// before the first dictation. Call once at launch. Skipped when the Apple
    /// engine is selected — no point holding a Whisper model in memory; the
    /// per-language fallback loads it on demand if ever needed.
    func preloadModel() {
        // Skip only when the Apple engine will actually carry sessions: it
        // needs a fixed language, so under auto-detect Whisper is the engine
        // and must preload as usual.
        if #available(macOS 26.0, *),
           AppSettings.shared.transcriptionEngine == .apple,
           AppSettings.shared.forcedLanguageCode != nil {
            Log.info("Apple engine selected — skipping Whisper model preload (loads on demand for fallback).")
            // Make sure the language's assets are on disk before first use.
            AppleSpeechEngine.preinstallAssets(languageCode: AppSettings.shared.forcedLanguageCode)
            return
        }
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
        // Effective language: per-app override (matched against the app being
        // dictated into — frontmost at start) wins over the global setting.
        // "auto" → nil; this decides the engine, so it must resolve up front.
        let frontmost = NSWorkspace.shared.frontmostApplication
        let profile = AppProfile.profile(
            for: frontmost?.bundleIdentifier,
            in: AppSettings.shared.appProfiles
        )
        let languageSetting = profile?.language ?? AppSettings.shared.language
        let language: String? = languageSetting == "auto" ? nil : languageSetting
        sessionLanguageCode = language
        if let override = profile?.language {
            Log.info("begin() — per-app language override for \(profile?.bundleID ?? "?"): \(override)")
        }
        let engine = selectEngine(languageCode: language)
        sessionEngine = engine
        sessionEngineKind = (engine === transcriber) ? .whisper : .apple
        // Per-app mic override rides the session engine; nil clears any
        // previous session's override.
        engine.inputDeviceUIDOverride = profile?.inputDeviceUID
        let deviceOverride = profile?.inputDeviceUID
        // A pending warm-window release is now moot — this session will use (and
        // re-arm) the engine. Cancel it so it can't tear the mic down mid-session.
        cancelWarmRelease()
        // An Apple-engine session runs its OWN capture; a warm Whisper VPIO
        // engine left flowing would capture in parallel the whole session —
        // double mic use, indicator stuck on, VPIO fighting the live path.
        if sessionEngineKind == .apple, transcriber.isMicWarm {
            releaseWarmMic(reason: "Apple engine session starting")
        }
        // Tell the processor whether to keep the engine warm when this session
        // stops, per the user's setting. (The actual warm engine, if any, is
        // adopted instantly inside start() → startRecordingLive.) Whisper-only;
        // the Apple engine never warm-idles.
        transcriber.setKeepWarm(AppSettings.shared.micWarmUp != .off)
        // HUD shows "preparing…" immediately for visual feedback, but the audio
        // "go" cue is held until the mic is actually capturing (see below) — on a
        // cold VPIO start the engine takes ~800ms to converge, and chiming "speak
        // now" before then loses the leading word into the dead-zone.
        setState(.preparing)
        OverlayController.shared.show()
        startSessionKeys()
        // Start loading the on-device cleanup model now, while the user speaks,
        // so end() doesn't pay its cold start. Returns immediately. The
        // incremental cleaner then works through confirmed sentences in the
        // background as they lock, so end() only waits on the tail.
        var onConfirmed: ((String) -> Void)?
        if AppSettings.shared.cleanupEnabled, SpeechCleaner.isAvailable {
            SpeechCleaner.prewarm()
            let cleaner = IncrementalCleaner(languageHint: language)
            incrementalCleaner = cleaner
            onConfirmed = { [weak cleaner] confirmed in
                cleaner?.ingest(confirmed: confirmed)
            }
        } else {
            incrementalCleaner = nil
        }
        engine.onConfirmedText = onConfirmed
        Task {
            do {
                try await engine.start(language: language)
            } catch let error as AppleSpeechEngineError {
                // Apple engine can't handle this language on this Mac — fall
                // back to Whisper transparently for THIS session. Tear the
                // half-built Apple session down first so nothing leaks.
                Log.info("Apple Speech unavailable (\(error.localizedDescription)) — falling back to Whisper for this session.")
                OverlayController.shared.toast("Using Whisper for this language")
                sessionEngine?.forceStop()
                sessionEngine = transcriber
                sessionEngineKind = .whisper
                transcriber.inputDeviceUIDOverride = deviceOverride
                transcriber.onConfirmedText = onConfirmed
                do {
                    try await transcriber.start(language: language)
                } catch {
                    fail(error)
                    return
                }
            } catch {
                fail(error)
                return
            }
            // start() only returns once the mic has delivered its first
            // captured buffer (or timed out), so now the "go" cue is honest.
            // If the user already released (push-to-talk) we may have been
            // moved out of .preparing; only advance + chime if still preparing.
            if state == .preparing {
                SoundFeedback.start()
                setState(.recording)
            }
            Log.info("begin() — now \(String(describing: state))")
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
        // Take ownership of this session's incremental cleaner; a new session
        // starting later must never reuse it.
        let cleaner = incrementalCleaner
        incrementalCleaner = nil
        let engine = sessionEngine ?? transcriber
        engine.onConfirmedText = nil
        var text = await engine.stop()
        // Log only the length — never the dictated content. The transcript can
        // contain passwords, 2FA codes, or private messages, and the unified log
        // is persisted and readable via Console/sysdiagnose.
        Log.info("end() — raw transcript: \(text.count) chars")

        // Optional on-device cleanup (remove self-corrections + filler).
        // Short utterances skip the model entirely — its per-call cost is fixed,
        // and one-liners rarely have anything to clean, so they insert instantly.
        if AppSettings.shared.cleanupEnabled, SpeechCleaner.isAvailable, !text.isEmpty,
           text.count >= SpeechCleaner.minCleanupLength {
            setState(.cleaning)
            HUDLiveState.shared.cleaningText = nil
            let onPartial: (String) -> Void = { partial in
                HUDLiveState.shared.cleaningText = partial
            }
            if let cleaner {
                text = await cleaner.finish(finalText: text, onPartial: onPartial)
            } else {
                text = await SpeechCleaner.clean(
                    text,
                    languageHint: sessionLanguageCode,
                    onPartial: onPartial
                )
            }
            HUDLiveState.shared.cleaningText = nil
        } else {
            cleaner?.cancel()
        }

        // Voice formatting commands ("new line" / "new paragraph") — applied last
        // so they operate on the final text that gets typed.
        if AppSettings.shared.voiceCommandsEnabled {
            text = VoiceCommands.apply(text)
        }

        // Cheap auto-capitalization (no LLM). English-only "i" fix for auto-detect
        // or an explicit English selection.
        if AppSettings.shared.autoCapitalize {
            let lang = sessionLanguageCode
            text = TextFormatter.autoCapitalize(text, english: lang == nil || lang == "en")
        }

        OverlayController.shared.hide()

        guard !text.isEmpty else {
            Log.info("end() — empty transcript, nothing to insert")
            // A capture-only session must resolve even when empty, or the
            // awaiting Shortcuts intent would hang.
            if resolveCapture(with: "") {
                setState(.idle)
                return
            }
            // Distinguish a dead/contended mic (delivered no audio at all) from a
            // genuinely silent session. Only warn when we actually reached
            // .recording — a fast push-to-talk release from .preparing legitimately
            // captures almost nothing and shouldn't read as a mic failure.
            if wasRecording, !engine.lastSessionCapturedAudio {
                OverlayController.shared.toast(
                    "🎤 No audio detected — check your microphone"
                )
            } else if wasRecording, engine.lastSessionSuppressedNonSpeech {
                // Audio flowed but the detector heard no speech — almost always the
                // wrong input is selected (e.g. AirPods that only picked up music
                // while you spoke at the Mac). Name the mic so the fix is obvious.
                if let mic = engine.activeInputDeviceName {
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

        lastTranscript = text
        // Capture-only session (Shortcuts "Dictate Text"): hand the transcript
        // to the awaiting intent instead of typing it.
        if resolveCapture(with: text) {
            setState(.idle)
            return
        }
        setState(.inserting)
        // Per-app overrides, resolved against the app being dictated into
        // (frontmost — this LSUIElement app never takes that spot). Precedence:
        // explicit submit intent > app profile > global setting.
        let frontmost = NSWorkspace.shared.frontmostApplication
        let profile = AppProfile.profile(
            for: frontmost?.bundleIdentifier,
            in: AppSettings.shared.appProfiles
        )
        if let profile {
            Log.info("insert: applying per-app profile for \(profile.bundleID)")
        }
        inserter.insert(
            text,
            directType: profile?.useClipboard.map { !$0 } ?? AppSettings.shared.directTyping,
            restoreClipboard: AppSettings.shared.restoreClipboard,
            pressReturn: pressReturn ?? profile?.pressReturn ?? AppSettings.shared.pressReturnAfterInsert
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
        _ = resolveCapture(with: "")   // never leave a Shortcuts intent hanging
        discardIncrementalCleaner()
        stopSessionKeys()
        OverlayController.shared.hide()
        setState(.idle)
    }

    /// Puts the last transcript back on the clipboard (with the concealed
    /// markers, so clipboard managers don't archive it) for manual pasting.
    func copyLastTranscript() {
        guard let text = lastTranscript else { return }
        TextInserter.copyConcealed(text)
        OverlayController.shared.toast("Last transcript copied — paste it where you need it")
    }

    /// Drop the session's incremental cleaner and its partial results
    /// (cancel/error paths — the transcript is being discarded).
    private func discardIncrementalCleaner() {
        incrementalCleaner?.cancel()
        incrementalCleaner = nil
        sessionEngine?.onConfirmedText = nil
        transcriber.onConfirmedText = nil
        HUDLiveState.shared.cleaningText = nil
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
            // Stop the recording loop ON THE SESSION'S ENGINE. For Whisper,
            // forceStop() routes through the processor's stopRecording(),
            // which — when warm-up is enabled — keeps the VPIO engine flowing
            // (warm idle) instead of fully releasing the mic; we then arm a
            // timer to release it. The Apple engine tears down whole.
            (sessionEngine ?? transcriber).forceStop()
            sessionEngineKind = nil
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
        _ = resolveCapture(with: "")   // never leave a Shortcuts intent hanging
        discardIncrementalCleaner()
        stopSessionKeys()
        transcriber.forceStop()
        OverlayController.shared.hide()
        lastError = error.localizedDescription
        Log.error("Dictation failed: \(error.localizedDescription)")
        OverlayController.shared.toast("⚠️ \(error.localizedDescription)")
        setState(.idle)
    }
}
