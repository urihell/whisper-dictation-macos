import Foundation
import Combine
import CoreML
import WhisperKit

/// Real-time transcription. Wraps WhisperKit's `AudioStreamTranscriber`, which
/// captures the mic itself and emits confirmed/unconfirmed segments as you
/// speak. Publishes `liveText` for the on-screen HUD.
@MainActor
final class StreamingTranscriber: ObservableObject {
    enum TranscriberError: LocalizedError {
        case tokenizerUnavailable
        var errorDescription: String? { "The transcription model failed to load." }
    }

    enum ModelError: LocalizedError {
        case isActive, isLoading, lastModel
        var errorDescription: String? {
            switch self {
            case .isActive: return "That model is currently in use. Switch to another model first."
            case .isLoading: return "That model is still loading. Cancel the load first."
            case .lastModel: return "Can't delete the only downloaded model — keep at least one."
            }
        }
    }

    /// What the HUD shows: confirmed text plus the live tail.
    @Published private(set) var liveText: String = ""
    /// Smoothed microphone level (0...1) driving the live HUD meter.
    @Published private(set) var audioLevel: Float = 0
    /// Whether the active session is capturing through Voice Isolation. Drives
    /// the passive "isolation on" badge in the HUD; set at session start, cleared
    /// on stop.
    @Published private(set) var voiceIsolationActive = false

    // Coalesces rapid live-transcript updates so the HUD refreshes at a calm,
    // readable rate (still showing corrections) instead of rewriting itself on
    // every re-decode wobble.
    private let liveTextSubject = PassthroughSubject<String, Never>()
    private var liveTextCancellable: AnyCancellable?

    init() {
        // Throttle on DispatchQueue.main, not RunLoop.main: the RunLoop scheduler
        // only fires in the default run-loop mode, so during transient UI/tracking
        // states (and when another app takes foreground) the live text could stall.
        // The dispatch scheduler is serviced across common modes.
        liveTextCancellable = liveTextSubject
            .throttle(for: .milliseconds(40), scheduler: DispatchQueue.main, latest: true)
            .removeDuplicates()
            .sink { [weak self] text in self?.liveText = text }
    }
    /// True only while blocking on the very first model load (nothing usable yet).
    @Published private(set) var isModelLoading = false
    /// The currently active (usable) model, or nil before the first load.
    @Published private(set) var loadedModel: String?
    /// The model currently loading in the background, or nil.
    @Published private(set) var loadingModel: String?
    /// Download progress (0...1) while a model is downloading; nil otherwise. Once
    /// the download completes the value is cleared and the Core ML compile (which
    /// reports no progress — it's a system service) runs as "optimizing".
    @Published private(set) var loadProgress: Double?
    /// When the Core ML / ANE compile ("optimizing") phase began, or nil when not
    /// optimizing. Drives the indeterminate progress bar + elapsed timer in the UI;
    /// this phase reports no real percentage, so elapsed time is all we can show.
    @Published private(set) var optimizingSince: Date?

    /// Called on the main actor when a background model load finishes and that
    /// model becomes active. The argument is the model name.
    var onModelReady: ((String) -> Void)?
    /// Called on the main actor when a background model load fails (e.g. no
    /// network on first download). The argument is the model name.
    var onModelLoadFailed: ((String) -> Void)?

    private var whisperKit: WhisperKit?
    private var loadedModelName: String?
    private var streamer: AudioStreamTranscriber?
    private var streamTask: Task<Void, Never>?
    private var backgroundLoad: Task<Void, Never>?
    /// Bumped on every session stop/teardown. `start()` captures it before its
    /// async model load and bails if it changed during the await — so a session
    /// that was cancelled (push-to-talk release, Escape) while the first model was
    /// still loading doesn't resume past the await and reopen the mic with no
    /// session. Mirrors `vadSessionToken`'s adopt-only-if-current pattern.
    private var sessionToken = 0

    // Latest pieces from the stream callback.
    private var confirmedText = ""
    private var tailText = ""
    /// The last text we chose to display — used to suppress transient backward
    /// truncations of the live tail (which read as flicker) without hiding real
    /// corrections or growth.
    private var lastShown = ""
    /// Language for this session (nil = auto), reused for the final pass on stop.
    private var sessionLanguage: String?
    /// End time (seconds, absolute in the session audio) of the last locked
    /// segment — the boundary past which the tail still needs decoding on stop.
    private var lastConfirmedEnd: Float = 0
    /// Sample count the streaming loop has already decoded (WhisperKit's
    /// lastBufferSize). Audio beyond this is the un-decoded tail at stop.
    private var lastDecodedSamples = 0

    // Speech-activity detection (SoundAnalysis) used to suppress silent sessions
    // and to confirm that hallucination-phrase suspects (a lone "Thank you")
    // were actually spoken — see isSpeechSegment.
    private var vad: SpeechActivityDetector? { vadHandle.detector }
    /// Hands the session's detector to the stream callback, which runs off the
    /// main actor. The detector is built asynchronously and adopted late, so the
    /// reference itself needs a thread-safe home; the detector's own state is
    /// already lock-guarded.
    private let vadHandle = VADHandle()

    private final class VADHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var _detector: SpeechActivityDetector?
        var detector: SpeechActivityDetector? {
            get { lock.withLock { _detector } }
            set { lock.withLock { _detector = newValue } }
        }
    }
    /// Bumped on every session start/teardown. The async VAD build adopts its
    /// result only if this still matches — so a detector that finishes loading
    /// after the session already stopped is discarded instead of lingering.
    private var vadSessionToken = 0
    private var fedSamples = 0

    private static let placeholder = "Waiting for speech..."
    /// Segments whose no-speech probability exceeds this are dropped (Whisper's
    /// default). Kept conservative so a real but quiet word is never filtered.
    private static let noSpeechThreshold: Float = 0.6

    var isLoaded: Bool { whisperKit != nil }

    /// Builds (and downloads/compiles if needed) a WhisperKit for `modelName`.
    private func makeWhisperKit(_ modelName: String) async throws -> WhisperKit {
        let base = Self.modelDownloadBase()
        Log.info("Loading model '\(modelName)' (downloads on first use) into \(base.path)…")
        // Download (or resolve a cached copy) explicitly so we can surface real
        // progress — first-run downloads are large and otherwise look frozen. An
        // already-downloaded model resolves near-instantly (progress jumps to 1).
        loadProgress = 0
        do {
            _ = try await WhisperKit.download(
                variant: modelName,
                downloadBase: base
            ) { [weak self] progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in self?.loadProgress = fraction }
            }
        } catch {
            loadProgress = nil
            throw error
        }
        // Download done; the remaining time is the one-time Core ML compile, which
        // reports no progress. Clear the determinate bar and mark the start of the
        // "optimizing" phase so the UI can show an indeterminate bar + elapsed time.
        loadProgress = nil
        optimizingSince = Date()
        defer { optimizingSince = nil }

        // Load via model + downloadBase (the model is now cached from the pre-
        // download above, so WhisperKit's own setup resolves it instantly). This
        // keeps the proven tokenizer-loading path: `load: true` is required so the
        // tokenizer loads (WhisperKit only auto-loads when a modelFolder is set,
        // and we pass downloadBase instead).
        // verbose:false / logLevel:.error keep WhisperKit from logging load and
        // decode details (incl. decoded text) to the unified log — matching this
        // app's privacy posture.
        // No prewarm: it load-unload-loads to trigger Core ML specialization with
        // lower peak memory, but the docs note it ~doubles load time. On a cold
        // cache (download + first ANE specialization is already slow) that made
        // first use painfully long. Fast first run matters more here than the
        // marginal peak-memory saving.
        // Pick the compute backend for *this* model. GPU (Metal) is the per-model
        // default: it loads in seconds. The Neural Engine is more power-efficient
        // but the first load of a model on it triggers a one-time macOS
        // optimization (multi-minute); the result is cached and reused after that.
        let compute: MLComputeUnits = AppSettings.shared.computeBackend(for: modelName) == .gpu
            ? .cpuAndGPU
            : .cpuAndNeuralEngine
        let computeOptions = ModelComputeOptions(
            audioEncoderCompute: compute,
            textDecoderCompute: compute
        )
        let config = WhisperKitConfig(
            model: modelName,
            downloadBase: base,
            computeOptions: computeOptions,
            // Custom processor so the mic input device is user-selectable; WhisperKit's
            // AudioStreamTranscriber otherwise always records the system default device.
            audioProcessor: SelectableInputAudioProcessor(),
            verbose: false,
            logLevel: .error,
            load: true
        )
        let wk = try await WhisperKit(config)
        Log.info("Model '\(modelName)' loaded. tokenizer=\(wk.tokenizer != nil)")
        return wk
    }

    /// Base decoding options shared by the live stream and the final pass:
    /// transcribe task, language, and Whisper's standard anti-hallucination
    /// thresholds.
    private static func baseDecodeOptions(language: String?) -> DecodingOptions {
        var o = DecodingOptions()
        o.task = .transcribe
        o.language = language
        o.detectLanguage = (language == nil)
        o.skipSpecialTokens = true
        o.suppressBlank = true
        o.noSpeechThreshold = 0.6
        o.logProbThreshold = -1.0
        o.compressionRatioThreshold = 2.4
        return o
    }

    /// Base options plus the user's custom-vocabulary prompt (opt-in; setting
    /// promptTokens disables WhisperKit's prefill cache, which slows streaming).
    private func decodeOptions(language: String?, tokenizer: any WhisperTokenizer) -> DecodingOptions {
        var o = Self.baseDecodeOptions(language: language)
        let terms = AppSettings.shared.vocabularyTerms.filter { !$0.isEmpty }
        if AppSettings.shared.vocabularyBiasing, !terms.isEmpty {
            var tokens = tokenizer.encode(text: " " + terms.joined(separator: ", "))
            if tokens.count > 200 { tokens = Array(tokens.suffix(200)) }
            o.promptTokens = tokens
            o.usePrefillPrompt = true
        }
        return o
    }

    /// Loads `modelName` in the background and switches to it when ready, while
    /// the current model stays usable. No-op if it's already active or loading.
    func requestModel(_ modelName: String) {
        if modelName == loadedModelName || modelName == loadingModel { return }
        Log.info("requestModel('\(modelName)') — loading in background")
        loadingModel = modelName
        backgroundLoad?.cancel()
        backgroundLoad = Task { [weak self] in
            guard let self else { return }
            do {
                let wk = try await self.makeWhisperKit(modelName)
                if Task.isCancelled { return }
                self.whisperKit = wk
                self.loadedModelName = modelName
                self.loadedModel = modelName
                self.loadingModel = nil
                Log.info("Switched active model to '\(modelName)'")
                self.onModelReady?(modelName)
            } catch {
                // A superseded/cancelled load (model switched again, or Cancel
                // pressed) throws on its way out — that's not a failure. Don't
                // clear the *newer* load's state or toast a spurious error.
                if error is CancellationError || Task.isCancelled { return }
                if self.loadingModel == modelName { self.loadingModel = nil }
                Log.error("Background model load failed for '\(modelName)': \(error.localizedDescription)")
                self.onModelLoadFailed?(modelName)
            }
        }
    }

    /// Forces a fresh load of the current model even though its name is
    /// unchanged — used when the compute backend changes, which only takes
    /// effect on a reload. The active model stays usable until the reload lands.
    func reloadActiveModel() {
        let name = loadedModelName ?? loadingModel ?? AppSettings.shared.modelName
        // Clear the guards so requestModel doesn't treat this as a no-op.
        loadedModelName = nil
        loadingModel = nil
        requestModel(name)
    }

    /// Ensures a usable model exists for a session. If one is already active, it
    /// is used immediately and the desired model (if different) loads in the
    /// background. Only blocks when nothing is loaded yet (first ever launch).
    private func ensureUsableModel(desired: String) async throws {
        if whisperKit == nil {
            isModelLoading = true
            defer { isModelLoading = false }
            let wk = try await makeWhisperKit(desired)
            whisperKit = wk
            loadedModelName = desired
            loadedModel = desired
        } else if loadedModelName != desired {
            requestModel(desired)
        }
    }

    private static func modelDownloadBase() -> URL { ModelManager.downloadBase }

    /// Cancels an in-flight background model load. Note: the underlying download
    /// may stop, but an ANE compile already in progress can run to completion in
    /// a system service — we just stop waiting for it and don't switch.
    func cancelModelLoad() {
        if let m = loadingModel { Log.info("Cancelling background load of '\(m)'") }
        backgroundLoad?.cancel()
        backgroundLoad = nil
        loadingModel = nil
        loadProgress = nil
    }

    /// Deletes a downloaded model from disk. Refuses to delete the active model,
    /// one that's currently loading, or the last remaining model.
    func deleteModel(_ name: String) throws {
        if name == loadedModelName { throw ModelError.isActive }
        if name == loadingModel { throw ModelError.isLoading }
        if ModelManager.downloadedModels().count <= 1 { throw ModelError.lastModel }
        try ModelManager.delete(name)
        Log.info("Deleted model '\(name)'")
        objectWillChange.send()
    }

    /// Begins streaming transcription using the active model. If the configured
    /// model isn't loaded yet, the active one is used now and the new one loads
    /// in the background (only the very first load blocks).
    /// Resolve the input device and the device-aware voice-processing decision,
    /// and apply both to the processor. Returns whether VPIO will be engaged.
    /// Used by `start()` to resolve the device + VPIO decision for a session.
    @discardableResult
    private func configureVoiceProcessing(on proc: SelectableInputAudioProcessor) -> Bool {
        // Resolve the persisted device UID to a live runtime ID; nil (system
        // default) when unset or the device isn't connected right now.
        let uid = AppSettings.shared.audioInputDeviceUID
        let device: DeviceID? = uid.isEmpty ? nil : SelectableInputAudioProcessor.deviceID(forUID: uid)
        if !uid.isEmpty, device == nil {
            Log.info("Selected input device not connected; using system default.")
        }
        proc.selectedDeviceID = device
        let engage = SelectableInputAudioProcessor.shouldEngageVoiceProcessing(forInputDevice: device)
        proc.voiceIsolationEnabled = engage
        return engage
    }

    /// Whether a VPIO engine is currently held warm between sessions.
    var isMicWarm: Bool {
        (whisperKit?.audioProcessor as? SelectableInputAudioProcessor)?.isWarmIdle ?? false
    }

    /// Fully release a warm VPIO engine and the microphone (warm-up Off, window
    /// expiry, app background/quit, device change).
    func releaseWarmMic() {
        (whisperKit?.audioProcessor as? SelectableInputAudioProcessor)?.releaseWarmEngine()
    }

    /// Set whether the processor keeps the VPIO engine warm when a session stops.
    func setKeepWarm(_ keep: Bool) {
        (whisperKit?.audioProcessor as? SelectableInputAudioProcessor)?.keepWarmOnStop = keep
    }

    func start(language: String?) async throws {
        // Defensive: fully tear down any prior/leaked stream before starting, so
        // overlapping loops can't run and keep the mic open.
        if let old = streamer { streamer = nil; await old.stopStreamTranscription() }
        streamTask?.cancel()
        streamTask = nil

        // Capture this session's token before the (possibly slow) first model load.
        sessionToken += 1
        let token = sessionToken

        try await ensureUsableModel(desired: AppSettings.shared.modelName)

        // If the session was stopped/cancelled while the model was loading (e.g.
        // push-to-talk released, or Escape), don't resume into opening the mic —
        // that would start capture with no live session. stop()/forceStop() have
        // already settled the engine (warm idle or released) via the .idle backstop.
        guard token == sessionToken else {
            Log.info("start() — session \(token) superseded during model load; aborting.")
            return
        }

        guard let whisperKit, let tokenizer = whisperKit.tokenizer else {
            throw TranscriberError.tokenizerUnavailable
        }

        // Clear any audio left in the shared processor so a new session never sees
        // the previous session's tail. (On the warm-idle path, startRecordingLive
        // also clears the rolling idle buffer as it adopts the engine — this is the
        // belt-and-suspenders clear for the cold/forwarded paths.)
        whisperKit.audioProcessor.purgeAudioSamples(keepingLast: 0)

        confirmedText = ""
        tailText = ""
        lastShown = ""
        lastConfirmedEnd = 0
        lastDecodedSamples = 0
        liveText = ""
        audioLevel = 0
        fedSamples = 0
        startVAD()

        sessionLanguage = language
        let options = decodeOptions(language: language, tokenizer: tokenizer)

        // Apply the user's chosen input device (0 = system default) and decide,
        // per device, whether to engage Apple's Voice Processing I/O. We engage it
        // for built-in/wired mics (the only way macOS Mic Mode Voice Isolation
        // applies there) and skip it for Bluetooth headsets like AirPods, which
        // self-isolate in hardware — a second VPIO pass just double-processes and
        // hurts pickup. Fully automatic; no user toggle.
        if let proc = whisperKit.audioProcessor as? SelectableInputAudioProcessor {
            let engage = configureVoiceProcessing(on: proc)
            voiceIsolationActive = engage
            Log.info("Voice processing \(engage ? "ON (built-in/wired mic)" : "OFF (Bluetooth self-isolates)") for this session.")
        }

        // Captured (strongly) by the stream callback below: the box outlives the
        // session and delivers the late-built detector across threads.
        let vadHandle = self.vadHandle
        let streamer = AudioStreamTranscriber(
            audioEncoder: whisperKit.audioEncoder,
            featureExtractor: whisperKit.featureExtractor,
            segmentSeeker: whisperKit.segmentSeeker,
            textDecoder: whisperKit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: whisperKit.audioProcessor,
            decodingOptions: options,
            // Confirm 1 segment back (vs the default 2) so text locks sooner — a
            // smaller un-decoded tail to re-decode on stop (faster paste) and a
            // quicker-settling live display. Default silenceThreshold (0.3) keeps
            // speech onset decoding promptly; hallucinations are handled by the
            // SoundAnalysis VAD + phrase filter, not an aggressive energy VAD.
            requiredSegmentsForConfirmation: 1
        ) { [weak self] _, newState in
            // Runs in the streamer's actor context (off the main actor). Do the
            // heavy work here — drop no-speech / hallucination segments and build
            // the cleaned candidate string — so the main actor only assigns state
            // and publishes. (Whisper emits "Thank you." etc. on silence, so we
            // filter by noSpeechProb and known-phrase text, with the VAD able to
            // vouch for phrases that were really spoken.)
            let vadNow = vadHandle.detector
            let confirmed = newState.confirmedSegments.filter { Self.isSpeechSegment($0, vad: vadNow) }.map(\.text).joined(separator: " ")
            let unconfirmed = newState.unconfirmedSegments.filter { Self.isSpeechSegment($0, vad: vadNow) }.map(\.text).joined(separator: " ")
            let current = newState.currentText
            let isIdle = (current == Self.placeholder)
            var livePartial = isIdle ? "" : current
            if confirmed.isEmpty, Self.isLikelySilenceHallucination(livePartial) {
                livePartial = ""
            }
            let tail = livePartial.isEmpty ? unconfirmed : livePartial
            // Only clean when there's something to publish — publish() discards
            // the candidate while idle (pauses), so don't pay for it there.
            let candidate = isIdle ? "" : Self.clean([confirmed, tail].filter { !$0.isEmpty }.joined(separator: " "))
            let level = newState.bufferEnergy.suffix(8).max() ?? 0
            let confirmedEnd = newState.lastConfirmedSegmentEndSeconds
            let decoded = newState.lastBufferSize
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.confirmedText = confirmed
                self.tailText = tail
                self.lastConfirmedEnd = confirmedEnd
                self.lastDecodedSamples = decoded
                self.feedVAD()
                self.publish(candidate: candidate, isIdle: isIdle)
                self.updateLevel(level)
            }
        }

        self.streamer = streamer
        Log.info("Starting stream transcription (language=\(language ?? "auto"))")
        streamTask = Task {
            do {
                try await streamer.startStreamTranscription()
                Log.info("Stream transcription loop ended")
            } catch {
                Log.error("Stream transcription error: \(error.localizedDescription)")
            }
        }

        // Don't return (and let the controller cue "speak now") until the mic is
        // actually capturing. On the VPIO path a COLD engine takes ~800ms to
        // converge and deliver its first buffer — speaking into that gap silently
        // loses the leading word(s). Block here until the first captured buffer
        // lands, so the caller's "go" chime + .recording state are honest. The
        // warm-adopt path delivers its first buffer in ~100ms (engine already
        // flowing), so this is effectively instant there — no regression.
        // Non-VPIO (Bluetooth) capture starts immediately, so skip the wait.
        if voiceIsolationActive {
            await waitForFirstCapturedBuffer(token: token)
        }
    }

    /// Polls until the audio processor has delivered its first captured buffer,
    /// the session is superseded (cancel/Escape/stop bumps `sessionToken`), or a
    /// safety timeout elapses. Fail-open: if the mic never produces audio (denied
    /// permission, dead device) we return after the timeout so dictation proceeds
    /// exactly as before rather than hanging on the "preparing" state forever.
    private func waitForFirstCapturedBuffer(token: Int) async {
        let pollNs: UInt64 = 20_000_000          // 20ms
        let maxPolls = 100                        // ~2s safety backstop
        for _ in 0..<maxPolls {
            guard token == sessionToken else { return }       // superseded → bail
            if !(whisperKit?.audioProcessor.audioSamples.isEmpty ?? true) {
                Log.info("Mic live — first buffer captured.")
                return
            }
            try? await Task.sleep(nanoseconds: pollNs)
        }
        Log.info("Mic-warmup wait timed out (~2s) — proceeding without first-buffer confirmation.")
    }

    /// Stops streaming and returns the cleaned final transcript.
    func stop() async -> String {
        // Capture the full audio + last-confirmed boundary before teardown.
        let samples = whisperKit?.audioProcessor.audioSamples
        let confirmedEnd = lastConfirmedEnd
        sessionToken += 1   // supersede any start() still awaiting its model load
        await streamer?.stopStreamTranscription()
        streamTask?.cancel()
        streamTask = nil
        streamer = nil
        audioLevel = 0
        voiceIsolationActive = false
        let suppress = vadSuppresses
        // Keep this session's detector alive past clearVAD(): the tail re-decode
        // and the final hallucination backstop below still consult its recorded
        // speech windows.
        let sessionVAD = vad
        Log.info("stop() — VAD \(sessionVAD?.stats ?? "n/a"), suppress=\(suppress)")
        clearVAD()

        guard !suppress else { return "" }

        // Fast path: if the streaming loop already decoded essentially all the
        // captured audio (it caught up before you stopped), the streamed text is
        // complete — paste it instantly, no re-decode.
        var text = Self.clean([confirmedText, tailText].filter { !$0.isEmpty }.joined(separator: " "))
        let undecoded = max(0, (samples?.count ?? 0) - lastDecodedSamples)
        let needsTail = undecoded > Int(Self.sampleRate * 0.4)

        // Slow path (only when stopped mid-flow): re-decode just the un-confirmed
        // tail — audio after the last locked segment — and append it to the
        // confirmed prefix, so the last words aren't dropped.
        if needsTail, let whisperKit, let tokenizer = whisperKit.tokenizer, let samples {
            let start = max(0, min(Int(confirmedEnd * Float(Self.sampleRate)), samples.count))
            let tailAudio = Array(samples[start...])
            if tailAudio.count > Int(Self.sampleRate * 0.2) {
                let opts = decodeOptions(language: sessionLanguage, tokenizer: tokenizer)
                if let results = try? await whisperKit.transcribe(audioArray: tailAudio, decodeOptions: opts),
                   !results.isEmpty {
                    // Tail segments are timed from the tail's start — offset
                    // them back onto the session clock for the VAD check.
                    let tailOffset = Double(start) / Self.sampleRate
                    let tailWords = Self.clean(
                        results.flatMap { $0.segments }
                            .filter { Self.isSpeechSegment($0, vad: sessionVAD, timeOffset: tailOffset) }
                            .map(\.text).joined(separator: " ")
                    )
                    let prefix = Self.clean(confirmedText)
                    text = [prefix, tailWords].filter { !$0.isEmpty }.joined(separator: " ")
                }
            }
        }

        guard !text.isEmpty else { return "" }
        // Whole-text backstop, session-level: the joined text has no timestamps,
        // so if the entire transcript is a known silence phrase, keep it only
        // when the detector heard speech somewhere in the session. (Per-segment
        // filtering above already did the time-aligned check.)
        if Self.isLikelySilenceHallucination(text), sessionVAD?.everSpeech != true {
            return ""
        }
        return Self.applyReplacements(text, AppSettings.shared.replacements)
    }

    /// Backstop teardown for non-stop() paths (errors, idle transitions): ensure
    /// no stream loop keeps running and the microphone is released. Safe to call
    /// when already idle (stopRecording is a no-op then).
    func forceStop() {
        sessionToken += 1   // supersede any start() still awaiting its model load
        streamTask?.cancel()
        streamTask = nil
        if let s = streamer {
            streamer = nil
            Task { await s.stopStreamTranscription() }
        }
        whisperKit?.audioProcessor.stopRecording()
        clearVAD()
        audioLevel = 0
        voiceIsolationActive = false
    }

    private static let sampleRate: Double = 16_000

    /// Whisper's silence hallucinations — multilingual phrase + caption-credit
    /// matching lives in `HallucinationFilter`. Used per-segment and as a
    /// backstop when nothing was confirmed.
    private static func isLikelySilenceHallucination(_ text: String) -> Bool {
        HallucinationFilter.isLikelySilenceHallucination(text)
    }

    /// A segment counts as speech only if it isn't flagged no-speech AND isn't a
    /// silence hallucination. Whisper often emits "Thank you." on silence with a
    /// *low* noSpeechProb (a confident hallucination), so the probability check
    /// alone misses it — the text has to be checked too. But a phrase match
    /// alone no longer condemns the segment: if the acoustic speech detector saw
    /// speech under the segment's time range, the phrase was really spoken —
    /// keep it. With no detector evidence (still loading, results lagging,
    /// genuine silence) the segment is dropped, exactly the old text-only
    /// behavior. `timeOffset` maps segment-relative times onto the session-audio
    /// clock (the stop() tail re-decode produces segments timed from the tail's
    /// start, not the session's).
    private static func isSpeechSegment(
        _ seg: TranscriptionSegment,
        vad: SpeechActivityDetector?,
        timeOffset: Double = 0
    ) -> Bool {
        guard seg.noSpeechProb <= noSpeechThreshold else { return false }
        guard HallucinationFilter.isLikelySilenceHallucination(seg.text) else { return true }
        guard let vad else { return false }
        return vad.sawSpeech(
            betweenSeconds: Double(seg.start) + timeOffset,
            and: Double(seg.end) + timeOffset
        )
    }

    /// Applies user replacements (heard → corrected), case-insensitively.
    private static func applyReplacements(_ text: String, _ map: [String: String]) -> String {
        guard !map.isEmpty else { return text }
        var result = text
        for (wrong, right) in map where !wrong.isEmpty {
            result = result.replacingOccurrences(
                of: wrong, with: right, options: [.caseInsensitive]
            )
        }
        return result
    }

    /// Smooths the raw mic level so the meter glides instead of jittering.
    private func updateLevel(_ raw: Float) {
        let clamped = max(0, min(1, raw))
        audioLevel = audioLevel * 0.6 + clamped * 0.4
    }

    /// True only when the detector ran long enough to be confident the session
    /// contained NO speech. Fail-open: unavailable detector, or too few results
    /// yet (short utterances), returns false — so real speech is never dropped.
    private var vadSuppresses: Bool {
        guard let vad else { return false }
        return vad.resultCount >= 3 && !vad.everSpeech
    }

    /// Builds the speech detector OFF the dictation-start path. Its init loads
    /// Apple's shared SoundAnalysis classifier, whose one-time Core ML/ANE compile
    /// can block — and can queue behind a large Whisper model's own ANE compile,
    /// freezing the start of dictation. The detector is best-effort
    /// instrumentation: `feedVAD` tolerates it arriving late and `vadSuppresses`
    /// fails open (never drops speech) until it's ready, so building it
    /// asynchronously is free and removes the stall.
    private func startVAD() {
        vadHandle.detector = nil
        vadSessionToken &+= 1
        let token = vadSessionToken
        Task.detached(priority: .utility) { [weak self] in
            let detector = SpeechActivityDetector()
            await self?.adoptVAD(detector, token: token)
        }
    }

    /// Adopts an asynchronously-built detector, unless the session changed or
    /// stopped while it was loading (token mismatch → discard).
    private func adoptVAD(_ detector: SpeechActivityDetector?, token: Int) {
        guard token == vadSessionToken else { return }
        vadHandle.detector = detector
    }

    /// Tears down the detector and invalidates any in-flight async build.
    private func clearVAD() {
        vadHandle.detector = nil
        vadSessionToken &+= 1
    }

    /// Feeds newly-captured mic samples to the speech detector.
    private func feedVAD() {
        guard let samples = whisperKit?.audioProcessor.audioSamples else { return }
        let n = samples.count
        if fedSamples < n {
            vad?.analyze(Array(samples[fedSamples..<n]))
            fedSamples = n
        } else if fedSamples > n {
            fedSamples = n  // buffer was purged/reset
        }
    }

    /// Publishes the (already-cleaned) candidate to the throttled HUD stream.
    private func publish(candidate: String, isIdle: Bool) {
        if vadSuppresses {
            // Confirmed silent session — keep "Listening…".
            lastShown = ""
            liveTextSubject.send("")
            return
        }
        // During pauses (isIdle) emit nothing — the HUD holds the last text.
        guard !isIdle else { return }
        // Suppress a transient backward truncation of the live tail: if the new
        // candidate is just a shorter PREFIX of what's already shown, the tail is
        // mid-redecode and will regrow — holding the longer text avoids the
        // backward "jump". Growth and genuine corrections (which diverge, not
        // truncate) still publish immediately, so responsiveness is unaffected.
        if !lastShown.isEmpty, lastShown.hasPrefix(candidate), candidate.count < lastShown.count {
            return
        }
        lastShown = candidate
        liveTextSubject.send(candidate)
    }

    /// Strips Whisper special tokens and non-speech annotations (e.g.
    /// `[BLANK_AUDIO]`, `(background noise)`, `*laughs*`, `♪`), then collapses
    /// whitespace — so only the dictated words remain. Runs on every streaming
    /// update, so the regexes are compiled once (statics below) rather than
    /// per-call.
    private static func clean(_ text: String) -> String {
        var s = text
        for regex in nonSpeechRegexes {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        s = whitespaceRegex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let nonSpeechRegexes: [NSRegularExpression] = [
        "<\\|[^|]*\\|>",          // Whisper special tokens, e.g. <|startoftranscript|>
        "\\[[^\\]]*\\]",          // square-bracket tags, e.g. [BLANK_AUDIO], [SILENCE], [Music]
        // parenthesized sound descriptions, e.g. (background noise), (upbeat music)
        "\\([^()]*(?:audio|silence|music|noise|applause|laughter|laughs|laughing|sound|wind|static|inaudible|blank|background|coughing|breathing|sighs|sighing|chuckles|sniff|beep|ringing|footsteps)[^()]*\\)",
        "\\*[^*]*\\*",            // asterisk actions, e.g. *laughs*
        "[♪♫🎵🎶]",               // musical notes
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static let whitespaceRegex = try! NSRegularExpression(pattern: "\\s+")
}
