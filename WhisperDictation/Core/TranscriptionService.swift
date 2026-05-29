import Foundation
import WhisperKit

/// Wraps WhisperKit: lazily loads the selected model and transcribes audio
/// samples. Model download/caching is handled entirely by WhisperKit.
@MainActor
final class TranscriptionService: ObservableObject {
    enum TranscriptionError: LocalizedError {
        case notLoaded
        var errorDescription: String? { "The transcription model failed to load." }
    }

    @Published private(set) var isModelLoading = false
    @Published private(set) var loadedModel: String?

    private var whisperKit: WhisperKit?
    private var loadedModelName: String?

    /// Transcribes 16 kHz mono samples. `language` is an ISO code, or `nil` to
    /// auto-detect.
    func transcribe(samples: [Float], language: String?) async throws -> String {
        guard !samples.isEmpty else { return "" }

        try await loadIfNeeded(AppSettings.shared.modelName)
        guard let whisperKit else { throw TranscriptionError.notLoaded }

        var options = DecodingOptions()
        options.task = .transcribe
        options.language = language
        options.detectLanguage = (language == nil)

        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
        return Self.clean(text)
    }

    func loadIfNeeded(_ modelName: String) async throws {
        if whisperKit != nil, loadedModelName == modelName { return }

        isModelLoading = true
        defer { isModelLoading = false }

        let config = WhisperKitConfig(model: modelName)
        whisperKit = try await WhisperKit(config)
        loadedModelName = modelName
        loadedModel = modelName
    }

    /// Strips Whisper special tokens (e.g. `<|startoftranscript|>`) and trims.
    private static func clean(_ text: String) -> String {
        text
            .replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
