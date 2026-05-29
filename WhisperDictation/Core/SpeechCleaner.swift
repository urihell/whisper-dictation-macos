import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Cleans dictated text with Apple's on-device language model (macOS 26+):
/// removes self-corrections (keeping the corrected wording), false starts, and
/// filler — while preserving the speaker's words, meaning, and language.
/// Everything runs on-device. Falls back to the original text on any problem.
///
/// To hide model cold-start latency, call `prewarm()` when dictation begins so
/// the model is warm by the time `clean(_:)` runs at the end.
final class SpeechCleaner {
    static let shared = SpeechCleaner()
    private init() {}

    /// A prewarmed `LanguageModelSession` (typed `Any` so this class can compile
    /// for the macOS 14 deployment target). Consumed by the next `clean` call.
    private var preparedSession: Any?

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

    /// Warms the on-device model (loads it into memory) so the cleanup pass at
    /// the end of dictation is fast. Safe to call repeatedly.
    func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else { return }
            if preparedSession == nil {
                let session = LanguageModelSession(instructions: Self.instructions)
                session.prewarm()
                preparedSession = session
                Log.info("SpeechCleaner: prewarmed session")
            }
        }
        #endif
    }

    /// Returns the cleaned text, or the original on any failure.
    static func clean(_ text: String, languageHint: String?) async -> String {
        await shared.clean(text, languageHint: languageHint)
    }

    func clean(_ text: String, languageHint: String?) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else { return text }

            // Reuse the prewarmed session if we have one (no context bleed —
            // it hasn't responded yet), else make a fresh one. One-shot: drop it
            // afterward so the next dictation prewarms a clean session.
            let session = (preparedSession as? LanguageModelSession)
                ?? LanguageModelSession(instructions: Self.instructions)
            preparedSession = nil

            do {
                // Greedy = deterministic + fastest. Cap output so a runaway
                // generation can't stall; generous enough not to truncate.
                let options = GenerationOptions(
                    sampling: .greedy,
                    maximumResponseTokens: max(96, trimmed.count)
                )
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
