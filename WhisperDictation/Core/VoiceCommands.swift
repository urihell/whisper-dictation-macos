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
    /// Breaks replace the surrounding gap entirely (whitespace consumed both
    /// sides). Localized for every language offered in Settings (en/es/he/fr/
    /// de/pt/zh) — always all active, matching how the hallucination filter
    /// works, since auto-detect sessions have no fixed language. Paragraph
    /// rules precede line rules per language so the longer command wins.
    private static let breakRules: [(String, String)] = [
        // English
        ("\\s*\\bnew[\\s-]+paragraphs?\\b[.,!?]*\\s*", "\n\n"),
        ("\\s*\\bnew[\\s-]+lines?\\b[.,!?]*\\s*", "\n"),
        ("\\s*\\bnewlines?\\b[.,!?]*\\s*", "\n"),
        // Spanish ([áa]: Whisper sometimes drops accents)
        ("\\s*\\bnuevo[\\s-]+p[áa]rrafo\\b[.,!?]*\\s*", "\n\n"),
        ("\\s*\\bnueva[\\s-]+l[íi]nea\\b[.,!?]*\\s*", "\n"),
        // French
        ("\\s*\\bnouveau[\\s-]+paragraphe\\b[.,!?]*\\s*", "\n\n"),
        ("\\s*\\bnouvelle[\\s-]+ligne\\b[.,!?]*\\s*", "\n"),
        ("\\s*\\b[àa] la ligne\\b[.,!?]*\\s*", "\n"),
        // German
        ("\\s*\\bneuer[\\s-]+absatz\\b[.,!?]*\\s*", "\n\n"),
        ("\\s*\\bneue[\\s-]+zeile\\b[.,!?]*\\s*", "\n"),
        // Portuguese
        ("\\s*\\bnovo[\\s-]+par[áa]grafo\\b[.,!?]*\\s*", "\n\n"),
        ("\\s*\\bnova[\\s-]+linha\\b[.,!?]*\\s*", "\n"),
        // Hebrew
        ("\\s*\\bפסקה חדשה\\b[.,!?]*\\s*", "\n\n"),
        ("\\s*\\bשורה חדשה\\b[.,!?]*\\s*", "\n"),
        // Chinese (simplified + traditional; no \b — CJK runs have no word
        // boundaries between ideographs, so boundary anchors would never match)
        ("\\s*新段落[.,!?，。！？]*\\s*", "\n\n"),
        ("\\s*[换換]行[.,!?，。！？]*\\s*", "\n"),
    ]

    /// A hyphen joins words: no space on either side.
    private static let joinRules: [(String, String)] = [
        ("\\s*\\bhyphen\\b\\s*", "-"),
    ]

    /// Closing punctuation attaches to the previous word: eat the leading space
    /// (and any punctuation Whisper appended to the spoken word), keep the space
    /// that follows. Singular forms only, so plurals like "commas" don't match.
    /// Localized for every Settings language; within each language, compound
    /// commands ("punto y coma") precede their prefix word ("punto") so the
    /// longer command wins. Accent alternates ([óo] etc.) forgive Whisper
    /// occasionally dropping diacritics.
    private static let punctRules: [(String, String)] = [
        // English
        ("\\s*\\bfull stop\\b[.,!?]*", "."),
        ("\\s*\\bperiod\\b[.,!?]*", "."),
        ("\\s*\\bcomma\\b[.,!?]*", ","),
        ("\\s*\\bquestion mark\\b[.,!?]*", "?"),
        ("\\s*\\bexclamation (?:mark|point)\\b[.,!?]*", "!"),
        ("\\s*\\bsemicolon\\b[.,!?]*", ";"),
        ("\\s*\\bcolon\\b[.,!?]*", ":"),
        ("\\s*\\bellipsis\\b[.,!?]*", "…"),
        // Spanish
        ("\\s*\\bpunto y coma\\b[.,!?]*", ";"),
        ("\\s*\\bdos puntos\\b[.,!?]*", ":"),
        ("\\s*\\bsigno de interrogaci[óo]n\\b[.,!?]*", "?"),
        ("\\s*\\bsigno de exclamaci[óo]n\\b[.,!?]*", "!"),
        ("\\s*\\bpunto\\b[.,!?]*", "."),
        ("\\s*\\bcoma\\b[.,!?]*", ","),
        // French
        ("\\s*\\bpoint[\\s-]virgule\\b[.,!?]*", ";"),
        ("\\s*\\bpoint d['’]interrogation\\b[.,!?]*", "?"),
        ("\\s*\\bpoint d['’]exclamation\\b[.,!?]*", "!"),
        ("\\s*\\bdeux[\\s-]points\\b[.,!?]*", ":"),
        ("\\s*\\bpoint\\b[.,!?]*", "."),
        ("\\s*\\bvirgule\\b[.,!?]*", ","),
        // German
        ("\\s*\\bdoppelpunkt\\b[.,!?]*", ":"),
        ("\\s*\\bsemikolon\\b[.,!?]*", ";"),
        ("\\s*\\bfragezeichen\\b[.,!?]*", "?"),
        ("\\s*\\bausrufezeichen\\b[.,!?]*", "!"),
        ("\\s*\\bpunkt\\b[.,!?]*", "."),
        ("\\s*\\bkomma\\b[.,!?]*", ","),
        // Portuguese
        ("\\s*\\bponto e v[íi]rgula\\b[.,!?]*", ";"),
        ("\\s*\\bponto de interroga[çc][ãa]o\\b[.,!?]*", "?"),
        ("\\s*\\bponto de exclama[çc][ãa]o\\b[.,!?]*", "!"),
        ("\\s*\\bdois pontos\\b[.,!?]*", ":"),
        ("\\s*\\bponto\\b[.,!?]*", "."),
        ("\\s*\\bv[íi]rgula\\b[.,!?]*", ","),
        // Hebrew
        ("\\s*\\bנקודה ופסיק\\b[.,!?]*", ";"),
        ("\\s*\\bנקודתיים\\b[.,!?]*", ":"),
        ("\\s*\\bסימן שאלה\\b[.,!?]*", "?"),
        ("\\s*\\bסימן קריאה\\b[.,!?]*", "!"),
        ("\\s*\\bנקודה\\b[.,!?]*", "."),
        ("\\s*\\bפסיק\\b[.,!?]*", ","),
        // Chinese (simplified + traditional; full-width output; no \b — CJK
        // runs have no word boundaries between ideographs)
        ("\\s*分[号號][.,!?，。！？]*", "；"),
        ("\\s*冒[号號][.,!?，。！？]*", "："),
        ("\\s*[问問][号號][.,!?，。！？]*", "？"),
        ("\\s*感[叹嘆][号號][.,!?，。！？]*", "！"),
        ("\\s*句[号號][.,!?，。！？]*", "。"),
        ("\\s*逗[号號][.,!?，。！？]*", "，"),
    ]

    static func apply(_ text: String) -> String {
        var s = text
        for (pattern, replacement) in breakRules + joinRules + punctRules {
            s = s.replacingOccurrences(
                of: pattern, with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        // Tidy: drop any stray space before closing punctuation (ASCII and
        // full-width CJK), collapse runs of spaces/tabs (but never newlines).
        s = s.replacingOccurrences(of: "[ \\t]+([,.;:!?…，。！？；：])", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        // Capitalize after spoken "period"/"new paragraph" etc. (shared logic).
        s = TextFormatter.capitalizeSentences(s)
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    }
}
