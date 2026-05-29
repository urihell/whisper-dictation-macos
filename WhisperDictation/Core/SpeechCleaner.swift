import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Cleans dictated text with Apple's on-device language model (macOS 26+):
/// removes self-corrections (keeping the corrected wording), false starts, and
/// filler — while preserving the speaker's words, meaning, and language.
/// Everything runs on-device. Falls back to the original text on any problem.
enum SpeechCleaner {
    /// Whether on-device cleanup can run (macOS 26 + Apple Intelligence ready).
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// Human-readable reason cleanup is unavailable, or nil if available.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Turn on Apple Intelligence in System Settings to enable cleanup."
            case .unavailable(.deviceNotEligible):
                return "This Mac doesn't support Apple Intelligence."
            case .unavailable(.modelNotReady):
                return "The on-device model is still downloading. Try again shortly."
            case .unavailable:
                return "On-device model unavailable."
            }
        }
        #endif
        return "Requires macOS 26 or later."
    }

    /// Returns the cleaned text, or the original on any failure.
    static func clean(_ text: String, languageHint: String?) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else { return text }
            do {
                let session = LanguageModelSession(instructions: instructions)
                let options = GenerationOptions(temperature: 0)
                let prompt = """
                Clean this dictation and return only the cleaned text:
                \"\"\"
                \(trimmed)
                \"\"\"
                """
                let response = try await session.respond(to: prompt, options: options)
                let cleaned = response.content.trimmingCharacters(in: .whitespacesAndNewlines)

                // Safety net: if the model emptied the text, or expanded it well
                // beyond the input (i.e. it "answered" instead of cleaning), keep
                // the original verbatim rather than insert something wrong.
                if cleaned.isEmpty || cleaned.count > trimmed.count * 2 + 40 {
                    Log.info("SpeechCleaner: result rejected (\(cleaned.count) vs \(trimmed.count) chars); using original")
                    return trimmed
                }
                Log.info("SpeechCleaner: cleaned \(trimmed.count) → \(cleaned.count) chars")
                return cleaned
            } catch {
                Log.error("SpeechCleaner failed: \(error.localizedDescription)")
                return trimmed
            }
        }
        #endif
        return text
    }

    private static let instructions = """
    You clean raw speech-to-text from a dictation app and return a corrected version.

    Rules:
    - If the speaker corrects themselves, keep ONLY the corrected wording and drop what it replaced. Example: "let's meet at five, no, at six" → "let's meet at six".
    - Remove filler words and false starts (e.g. "um", "uh", repeated restarts).
    - Otherwise keep the text verbatim: preserve the original wording, meaning, punctuation, and language. Never translate, summarize, add to, or answer the content.
    - Output ONLY the cleaned text — no quotes, labels, or commentary.
    """
}
