import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Cleans dictated text with Apple's on-device language model (macOS 26+):
/// removes self-corrections (keeping the corrected wording), false starts, and
/// filler — while preserving the speaker's words, meaning, and language.
/// Everything runs on-device. Falls back to the original text on any problem.
///
/// To hide model cold-start latency, `prewarm()` is called when dictation
/// begins (see DictationController.begin), so the model is loading while the
/// user speaks and `clean(_:)` at the end pays only the generation cost.
enum SpeechCleaner {
    #if canImport(FoundationModels)
    /// A session created (and prewarmed) at dictation start, consumed by the
    /// next `clean()` call. Consumed — not reused: a `LanguageModelSession`
    /// accumulates its conversation as context, so carrying one across
    /// dictations would feed earlier transcripts into later prompts (a privacy
    /// leak, and a drift risk). Main-actor confined: prewarm() and clean() are
    /// both called from the dictation controller on the main actor.
    @available(macOS 26.0, *)
    @MainActor
    private enum Prewarmed {
        static var session: LanguageModelSession?
    }
    #endif

    /// Kick off the model load so it happens while the user is speaking.
    /// Call when a dictation session begins and cleanup is enabled; a cheap
    /// no-op when the model is unavailable.
    @MainActor
    static func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else { return }
            let session = LanguageModelSession(instructions: instructions)
            session.prewarm()
            Prewarmed.session = session
        }
        #endif
    }
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

    /// Below this many characters, cleanup isn't worth the model's fixed
    /// per-call cost: one-liners ("reply yes to that email") rarely contain
    /// filler or self-corrections, and skipping the call makes them insert
    /// instantly. Checked by the controller before entering `.cleaning`.
    static let minCleanupLength = 60

    /// Returns the cleaned text, or the original on any failure.
    ///
    /// `onPartial` (optional) receives the cumulative cleaned text as the model
    /// generates it — used to stream the result into the HUD so the wait reads
    /// as progress instead of a stall. Same total latency either way.
    ///
    /// Note: on-device generation has a large fixed per-call latency (measured
    /// ~7s cold on current hardware), largely independent of input size. The
    /// prewarmed session from `prewarm()` shaves the model-load portion; the
    /// generation cost remains. Run only when the user opts in.
    @MainActor
    static func clean(
        _ text: String,
        languageHint: String?,
        onPartial: ((String) -> Void)? = nil
    ) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else { return text }
            // Use (and consume) the session prewarmed at dictation start, if any.
            let session: LanguageModelSession
            if let warmed = Prewarmed.session {
                Prewarmed.session = nil
                session = warmed
            } else {
                session = LanguageModelSession(instructions: instructions)
            }
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
                let start = Date()
                let raw: String
                if let onPartial {
                    // Stream snapshots so the HUD shows the cleaned text forming.
                    var latest = ""
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        latest = snapshot.content
                        onPartial(latest.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    raw = latest
                } else {
                    raw = try await session.respond(to: prompt, options: options).content
                }
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                Log.info("SpeechCleaner: respond \(ms)ms")

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
