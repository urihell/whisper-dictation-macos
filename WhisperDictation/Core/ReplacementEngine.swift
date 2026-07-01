import Foundation

/// Applies the user's "heard → corrected" replacements to the final transcript.
///
/// Two guarantees the naive `replacingOccurrences` approach lacked:
///  - **Whole-word matching** — a rule like `cat → Katherine` must not rewrite
///    "category". Keys are wrapped in word-boundary lookarounds rather than
///    `\b` so keys that start or end with non-word characters ("c++", "-ish")
///    still anchor correctly.
///  - **Deterministic order** — `[String: String]` iteration order varies run to
///    run, so overlapping rules ("new york city" vs "new york") could produce
///    different text on different runs. Rules apply longest-key-first (ties
///    alphabetical), so the most specific rule always wins.
enum ReplacementEngine {
    static func apply(_ text: String, rules: [String: String]) -> String {
        guard !text.isEmpty, !rules.isEmpty else { return text }
        var result = text
        let orderedKeys = rules.keys
            .filter { !$0.isEmpty }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        for key in orderedKeys {
            guard let replacement = rules[key] else { continue }
            // Lookarounds instead of \b: they hold at string edges and around
            // keys whose first/last character isn't a word character.
            let pattern = "(?<!\\w)" + NSRegularExpression.escapedPattern(for: key) + "(?!\\w)"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                // Escaped so "$" in a correction is inserted literally, not
                // interpreted as a capture-group reference.
                withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
            )
        }
        return result
    }
}
