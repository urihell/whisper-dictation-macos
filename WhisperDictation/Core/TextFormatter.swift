import Foundation

/// Cheap, always-fast text tidying applied to the final transcript — no model
/// calls. Whisper usually capitalizes already, so this is a safety net plus the
/// things it misses: the very first letter, restarts after line breaks, and the
/// English standalone "i".
enum TextFormatter {
    /// Capitalize the first letter of the text, the first letter after a
    /// sentence-ending mark (. ! ?), and the first letter after a line break.
    /// ASCII-focused (operates on a–z); leaves already-uppercase and accented
    /// starts untouched, which is the safe default for non-English text.
    static func capitalizeSentences(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        // Boundary: start of string, sentence mark + horizontal space(s), or
        // newline(s) + optional horizontal space — followed by a lowercase letter.
        let pattern = "(?:^|[.!?][ \\t]+|\\n+[ \\t]*)([a-z])"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = text
        // Reversed so earlier replacements don't shift later match ranges.
        for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let letterRange = match.range(at: 1)
            guard let r = Range(letterRange, in: result) else { continue }
            result.replaceSubrange(r, with: ns.substring(with: letterRange).uppercased())
        }
        return result
    }

    /// English: a standalone lowercase "i" (incl. contractions like "i'm",
    /// "i'll") becomes "I". Case-sensitive so existing "I" is left alone.
    static func fixStandaloneI(_ text: String) -> String {
        guard text.contains("i") else { return text }
        guard let re = try? NSRegularExpression(pattern: "\\bi\\b") else { return text }
        let ns = text as NSString
        var result = text
        for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard let r = Range(match.range, in: result) else { continue }
            result.replaceSubrange(r, with: "I")
        }
        return result
    }

    /// Full auto-capitalize pass. `english` enables the "i" → "I" fix.
    static func autoCapitalize(_ text: String, english: Bool) -> String {
        var s = capitalizeSentences(text)
        if english { s = fixStandaloneI(s) }
        return s
    }
}
