import Foundation

/// Turns spoken formatting commands into actual formatting in the final
/// transcript. Scoped to line/paragraph breaks for now — Whisper never inserts
/// these on its own, and the phrases rarely occur literally, so they're safe to
/// apply unconditionally. (Punctuation words like "comma"/"period" are
/// deliberately excluded: Whisper already punctuates, and they collide with
/// normal speech — e.g. "the Jurassic period".)
enum VoiceCommands {
    /// (regex, replacement). Whisper may capitalize a command and add trailing
    /// punctuation ("…done. New line. Next…"), and may hear a space or hyphen, so
    /// the patterns absorb surrounding whitespace + trailing punctuation and
    /// allow "new line" / "new-line" / "newline".
    private static let rules: [(pattern: String, replacement: String)] = [
        ("\\s*\\bnew[\\s-]+paragraphs?\\b[.,!?]*\\s*", "\n\n"),
        ("\\s*\\bnew[\\s-]+lines?\\b[.,!?]*\\s*", "\n"),
        ("\\s*\\bnewlines?\\b[.,!?]*\\s*", "\n"),
    ]

    /// Applies the commands to `text`. No-op if nothing matches.
    static func apply(_ text: String) -> String {
        var result = text
        for rule in rules {
            result = result.replacingOccurrences(
                of: rule.pattern,
                with: rule.replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        // A command can leave a leading/trailing break; trim spaces but keep
        // intentional newlines (e.g. ending on "new line").
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    }
}
