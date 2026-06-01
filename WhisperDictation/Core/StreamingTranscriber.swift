import Foundation
import Combine
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
    /// True only while blocking on the very first model load (nothing usable yet).
    @Published private(set) var isModelLoading = false
    /// The currently active (usable) model, or nil before the first load.
    @Published private(set) var loadedModel: String?
    /// The model currently loading in the background, or nil.
    @Published private(set) var loadingModel: String?

    /// Called on the main actor when a background model load finishes and that
    /// model becomes active. The argument is the model name.
    var onModelReady: ((String) -> Void)?

    private var whisperKit: WhisperKit?
    private var loadedModelName: String?
    private var streamer: AudioStreamTranscriber?
    private var streamTask: Task<Void, Never>?
    private var backgroundLoad: Task<Void, Never>?

    // Latest pieces from the stream callback.
    private var confirmedText = ""
    private var tailText = ""

    // Voice gate state (absolute-energy, session-level only). A session counts
    // as real speech once absolute mic loudness crosses the floor. This is used
    // ONLY to suppress an entirely-silent session — it never removes words from
    // real speech.
    private var heardSpeech = false
    private var maxEnergy: Float = 0

    private static let placeholder = "Waiting for speech..."
    /// Segments whose no-speech probability exceeds this are dropped (Whisper's
    /// default). Kept conservative so a real but quiet word is never filtered.
    private static let noSpeechThreshold: Float = 0.6
    /// A session counts as real speech once absolute mic RMS crosses this floor.
    /// WhisperKit's VAD uses *relative* energy (normalized to recent peaks),
    /// which clears its threshold even in a quiet room and lets the decoder
    /// hallucinate; absolute loudness is the reliable signal. Calibrated between
    /// this mic's silence (~0.023) and quiet speech (~0.041). It only suppresses
    /// a wholly-silent session — it never drops words — so erring low is safe.
    private static let speechEnergyFloor: Float = 0.030

    var isLoaded: Bool { whisperKit != nil }

    /// Builds (and downloads/compiles if needed) a WhisperKit for `modelName`.
    private func makeWhisperKit(_ modelName: String) async throws -> WhisperKit {
        let base = Self.modelDownloadBase()
        Log.info("Loading model '\(modelName)' (downloads on first use) into \(base.path)…")
        // `load: true` is required: WhisperKit only auto-loads (which loads the
        // tokenizer) when a modelFolder is passed. We pass downloadBase instead,
        // so without this the tokenizer stays nil and streaming can't start.
        let config = WhisperKitConfig(model: modelName, downloadBase: base, load: true)
        let wk = try await WhisperKit(config)
        Log.info("Model '\(modelName)' loaded. tokenizer=\(wk.tokenizer != nil)")
        return wk
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
                self.loadingModel = nil
                Log.error("Background model load failed for '\(modelName)': \(error.localizedDescription)")
            }
        }
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
    func start(language: String?) async throws {
        try await ensureUsableModel(desired: AppSettings.shared.modelName)
        guard let whisperKit, let tokenizer = whisperKit.tokenizer else {
            throw TranscriberError.tokenizerUnavailable
        }

        confirmedText = ""
        tailText = ""
        liveText = ""
        audioLevel = 0
        heardSpeech = false
        maxEnergy = 0

        var options = DecodingOptions()
        options.task = .transcribe
        options.language = language
        options.detectLanguage = (language == nil)
        // Suppress non-speech / blank output at the source. (Not setting
        // withoutTimestamps — the streaming segment confirmation needs them.)
        options.skipSpecialTokens = true
        options.suppressBlank = true
        // Anti-hallucination guards (OpenAI Whisper's standard thresholds). On
        // silence/near-silence the decoder otherwise emits artifacts like
        // "Thank you." These mark such output as no-speech / low-confidence so it
        // is dropped or retried rather than surfaced.
        options.noSpeechThreshold = 0.6
        options.logProbThreshold = -1.0
        options.compressionRatioThreshold = 2.4

        // Custom vocabulary: seed the decoder prompt with the user's terms so
        // names/jargon are recognized. Opt-in — setting promptTokens disables
        // WhisperKit's prefill cache, which slows live streaming noticeably.
        let terms = AppSettings.shared.vocabularyTerms.filter { !$0.isEmpty }
        if AppSettings.shared.vocabularyBiasing, !terms.isEmpty {
            var tokens = tokenizer.encode(text: " " + terms.joined(separator: ", "))
            if tokens.count > 200 { tokens = Array(tokens.suffix(200)) }
            options.promptTokens = tokens
            options.usePrefillPrompt = true
            Log.info("Vocabulary prompt: \(terms.count) terms, \(tokens.count) tokens (prefill cache off)")
        }

        let streamer = AudioStreamTranscriber(
            audioEncoder: whisperKit.audioEncoder,
            featureExtractor: whisperKit.featureExtractor,
            segmentSeeker: whisperKit.segmentSeeker,
            textDecoder: whisperKit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: whisperKit.audioProcessor,
            decodingOptions: options,
            // Raise WhisperKit's VAD silence threshold (default 0.3) so quiet
            // background noise between words is treated as silence and skipped
            // rather than decoded into hallucinations.
            silenceThreshold: 0.4
        ) { [weak self] _, newState in
            // Runs in the actor's context. Reduce to Sendable Strings here,
            // then hop to the main actor to publish. Drop high no-speech-
            // probability segments so Whisper's silence hallucinations (e.g.
            // "Thank you.") are never displayed or inserted.
            let confirmed = newState.confirmedSegments.filter(Self.isSpeechSegment).map(\.text).joined(separator: " ")
            let unconfirmed = newState.unconfirmedSegments.filter(Self.isSpeechSegment).map(\.text).joined(separator: " ")
            let current = newState.currentText
            // Recent peak relative energy (0...1) for the meter's liveliness.
            let level = newState.bufferEnergy.suffix(8).max() ?? 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Absolute RMS of the last ~0.3s — the reliable silence signal.
                let samples = self.whisperKit?.audioProcessor.audioSamples ?? []
                let recent = samples.count > 4800 ? Array(samples.suffix(4800)) : Array(samples)
                let absEnergy = recent.isEmpty ? 0 : AudioProcessor.calculateAverageEnergy(of: recent)
                self.apply(confirmed: confirmed, unconfirmed: unconfirmed, current: current, absEnergy: absEnergy)
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
    }

    /// Stops streaming and returns the cleaned final transcript.
    func stop() async -> String {
        await streamer?.stopStreamTranscription()
        streamTask?.cancel()
        streamTask = nil
        streamer = nil
        audioLevel = 0
        Log.info("stop() — heardSpeech=\(heardSpeech), maxEnergy=\(maxEnergy), floor=\(Self.speechEnergyFloor)")

        // Insert the FULL transcript so no spoken word is ever dropped. Suppress
        // only when the whole session was silent (no real speech detected) or the
        // result is just a known silence hallucination.
        let cleaned = Self.clean([confirmedText, tailText].filter { !$0.isEmpty }.joined(separator: " "))
        guard heardSpeech, !cleaned.isEmpty, !Self.isLikelySilenceHallucination(cleaned) else { return "" }
        return Self.applyReplacements(cleaned, AppSettings.shared.replacements)
    }

    /// Common Whisper hallucinations on silence (YouTube-caption training
    /// artifacts). Used only as a backstop when nothing was confirmed.
    private static let silenceHallucinations: Set<String> = [
        "thank you",
        "thank you very much",
        "thanks for watching",
        "thank you for watching",
    ]

    private static func isLikelySilenceHallucination(_ text: String) -> Bool {
        let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,!?…"))
        let normalized = text.lowercased().trimmingCharacters(in: trim)
        return silenceHallucinations.contains(normalized)
    }

    /// A segment counts as speech only if it isn't flagged no-speech AND isn't a
    /// known silence hallucination. Whisper often emits "Thank you." on silence
    /// with a *low* noSpeechProb (a confident hallucination), so the probability
    /// check alone misses it — reject the phrase by text too.
    private static func isSpeechSegment(_ seg: TranscriptionSegment) -> Bool {
        guard seg.noSpeechProb <= noSpeechThreshold else { return false }
        return !isLikelySilenceHallucination(seg.text)
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

    private func apply(confirmed: String, unconfirmed: String, current: String, absEnergy: Float) {
        // Session-level voice gate: once absolute loudness crosses the floor,
        // this session has real speech. This NEVER drops words — it only lets us
        // suppress a session that was silent throughout (the source of
        // accumulating hallucinations).
        maxEnergy = max(maxEnergy, absEnergy)
        if maxEnergy > Self.speechEnergyFloor { heardSpeech = true }

        confirmedText = confirmed
        let isIdle = (current == Self.placeholder)
        var livePartial = isIdle ? "" : current
        // Belt-and-suspenders: the live partial has no noSpeechProb, so before
        // any real speech, drop a standalone known hallucination by text too.
        if confirmed.isEmpty, Self.isLikelySilenceHallucination(livePartial) {
            livePartial = ""
        }
        tailText = livePartial.isEmpty ? unconfirmed : livePartial
        let candidate = Self.clean([confirmedText, tailText].filter { !$0.isEmpty }.joined(separator: " "))

        guard heardSpeech else {
            // No real speech yet — keep the HUD on "Listening…" so silence
            // hallucinations never show.
            liveText = ""
            return
        }
        if isIdle {
            liveText = candidate
        } else if !candidate.isEmpty {
            // Hold the last text through transient empties (anti-flicker).
            liveText = candidate
        }
    }

    /// Strips Whisper special tokens and non-speech annotations (e.g.
    /// `[BLANK_AUDIO]`, `(background noise)`, `*laughs*`, `♪`), then collapses
    /// whitespace — so only the dictated words remain.
    private static func clean(_ text: String) -> String {
        var s = text
        for pattern in nonSpeechPatterns {
            s = s.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let nonSpeechPatterns: [String] = [
        "<\\|[^|]*\\|>",          // Whisper special tokens, e.g. <|startoftranscript|>
        "\\[[^\\]]*\\]",          // square-bracket tags, e.g. [BLANK_AUDIO], [SILENCE], [Music]
        // parenthesized sound descriptions, e.g. (background noise), (upbeat music)
        "\\([^()]*(?:audio|silence|music|noise|applause|laughter|laughs|laughing|sound|wind|static|inaudible|blank|background|coughing|breathing|sighs|sighing|chuckles|sniff|beep|ringing|footsteps)[^()]*\\)",
        "\\*[^*]*\\*",            // asterisk actions, e.g. *laughs*
        "[♪♫🎵🎶]",               // musical notes
    ]
}
