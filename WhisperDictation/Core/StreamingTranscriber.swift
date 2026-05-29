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

    /// What the HUD shows: confirmed text plus the live tail.
    @Published private(set) var liveText: String = ""
    @Published private(set) var isModelLoading = false
    @Published private(set) var loadedModel: String?

    private var whisperKit: WhisperKit?
    private var loadedModelName: String?
    private var streamer: AudioStreamTranscriber?
    private var streamTask: Task<Void, Never>?

    // Latest pieces from the stream callback.
    private var confirmedText = ""
    private var tailText = ""

    private static let placeholder = "Waiting for speech..."

    var isLoaded: Bool { whisperKit != nil }

    func loadIfNeeded(_ modelName: String) async throws {
        if whisperKit != nil, loadedModelName == modelName { return }

        isModelLoading = true
        defer { isModelLoading = false }

        let base = Self.modelDownloadBase()
        Log.info("Loading model '\(modelName)' (downloads on first use) into \(base.path)…")
        // `load: true` is required: WhisperKit only auto-loads (which loads the
        // tokenizer) when a modelFolder is passed. We pass downloadBase instead,
        // so without this the tokenizer stays nil and streaming can't start.
        let config = WhisperKitConfig(model: modelName, downloadBase: base, load: true)
        whisperKit = try await WhisperKit(config)
        loadedModelName = modelName
        loadedModel = modelName
        Log.info("Model '\(modelName)' loaded. tokenizer=\(whisperKit?.tokenizer != nil)")
    }

    /// Where WhisperKit downloads/caches models. We override the default
    /// (`~/Documents/huggingface`), which a non-sandboxed app cannot write to
    /// on macOS 13+ without Documents-folder access (TCC). Application Support
    /// is always writable.
    private static func modelDownloadBase() -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("WhisperDictation", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport
    }

    /// Loads the model (if needed) and begins streaming transcription.
    func start(language: String?) async throws {
        try await loadIfNeeded(AppSettings.shared.modelName)
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
        return Self.clean([confirmedText, tailText].filter { !$0.isEmpty }.joined(separator: " "))
    }

    private func apply(confirmed: String, unconfirmed: String, current: String) {
        confirmedText = confirmed
        // Prefer the live partial decode; fall back to the last segmented tail.
        let livePartial = (current == Self.placeholder) ? "" : current
        tailText = livePartial.isEmpty ? unconfirmed : livePartial
        liveText = Self.clean([confirmedText, tailText].filter { !$0.isEmpty }.joined(separator: " "))
    }

    /// Strips Whisper special tokens and collapses whitespace.
    private static func clean(_ text: String) -> String {
        let stripped = text.replacingOccurrences(
            of: "<\\|[^|]*\\|>", with: "", options: .regularExpression
        )
        let collapsed = stripped.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
