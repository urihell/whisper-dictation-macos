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

    private static let placeholder = "Waiting for speech..."

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

        var options = DecodingOptions()
        options.task = .transcribe
        options.language = language
        options.detectLanguage = (language == nil)
        // Suppress non-speech / blank output at the source. (Not setting
        // withoutTimestamps — the streaming segment confirmation needs them.)
        options.skipSpecialTokens = true
        options.suppressBlank = true

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
            decodingOptions: options
        ) { [weak self] _, newState in
            // Runs in the actor's context. Reduce to Sendable Strings here,
            // then hop to the main actor to publish.
            let confirmed = newState.confirmedSegments.map(\.text).joined(separator: " ")
            let unconfirmed = newState.unconfirmedSegments.map(\.text).joined(separator: " ")
            let current = newState.currentText
            Task { @MainActor [weak self] in
                self?.apply(confirmed: confirmed, unconfirmed: unconfirmed, current: current)
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
        let cleaned = Self.clean([confirmedText, tailText].filter { !$0.isEmpty }.joined(separator: " "))
        return Self.applyReplacements(cleaned, AppSettings.shared.replacements)
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

    private func apply(confirmed: String, unconfirmed: String, current: String) {
        confirmedText = confirmed
        // Prefer the live partial decode; fall back to the last segmented tail.
        let livePartial = (current == Self.placeholder) ? "" : current
        tailText = livePartial.isEmpty ? unconfirmed : livePartial
        liveText = Self.clean([confirmedText, tailText].filter { !$0.isEmpty }.joined(separator: " "))
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
