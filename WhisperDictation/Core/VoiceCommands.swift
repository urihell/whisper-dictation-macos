import Foundation

/// Turns spoken formatting commands into real formatting in the final transcript.
///
/// Two classes:
///  - **Breaks** ("new line" / "new paragraph") — unambiguous; Whisper never
///    inserts breaks itself.
///  - **Punctuation** ("comma", "period", "question mark", …) — always-on when
///    enabled, matching Apple/Dragon dictation. This is intentionally literal:
///    "the Jurassic period" becomes "the Jurassic." The Settings toggle disables
///    the whole feature for anyone who doesn't want command interpretation.
enum VoiceCommands {
    /// Breaks replace the surrounding gap entirely (whitespace consumed both sides).
    private static let breakRules: [(String, String)] = [
        ("\\s*\\bnew[\\s-]+paragraphs?\\b[.,!?]*\\s*", "\n\n"),
        ("\\s*\\bnew[\\s-]+lines?\\b[.,!?]*\\s*", "\n"),
        ("\\s*\\bnewlines?\\b[.,!?]*\\s*", "\n"),
    ]

    /// A hyphen joins words: no space on either side.
    private static let joinRules: [(String, String)] = [
        ("\\s*\\bhyphen\\b\\s*", "-"),
    ]

    /// Closing punctuation attaches to the previous word: eat the leading space
    /// (and any punctuation Whisper appended to the spoken word), keep the space
    /// that follows. Singular forms only, so plurals like "commas" don't match.
    private static let punctRules: [(String, String)] = [
        ("\\s*\\bfull stop\\b[.,!?]*", "."),
        ("\\s*\\bperiod\\b[.,!?]*", "."),
        ("\\s*\\bcomma\\b[.,!?]*", ","),
        ("\\s*\\bquestion mark\\b[.,!?]*", "?"),
        ("\\s*\\bexclamation (?:mark|point)\\b[.,!?]*", "!"),
        ("\\s*\\bsemicolon\\b[.,!?]*", ";"),
        ("\\s*\\bcolon\\b[.,!?]*", ":"),
        ("\\s*\\bellipsis\\b[.,!?]*", "…"),
    ]

    static func apply(_ text: String) -> String {
        var s = text
        for (pattern, replacement) in breakRules + joinRules + punctRules {
            s = s.replacingOccurrences(
                of: pattern, with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        // Tidy: drop any stray space before closing punctuation, collapse runs of
        // spaces/tabs (but never newlines).
        s = s.replacingOccurrences(of: "[ \\t]+([,.;:!?…])", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        s = capitalizeSentences(s)
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    }

    /// Capitalize the first letter after a sentence-ending mark or a paragraph
    /// break, so a spoken "period"/"new paragraph" starts the next word uppercase.
    private static func capitalizeSentences(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "([.!?][ \\t]+|\\n{2,})([a-z])") else { return text }
        let ns = text as NSString
        var result = text
        for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let letterRange = match.range(at: 2)
            guard let r = Range(letterRange, in: result) else { continue }
            result.replaceSubrange(r, with: ns.substring(with: letterRange).uppercased())
        }
        return result
    }
}
