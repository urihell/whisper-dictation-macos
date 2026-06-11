import Foundation

/// Detects Whisper's well-known "silence hallucinations" — phrases the model
/// emits on silent or near-silent audio, learned from YouTube/TV caption
/// training data ("Thank you for watching", "ご視聴ありがとうございました",
/// Amara.org subtitle credits, broadcaster credits, …). These often carry a
/// *low* noSpeechProb (confident hallucinations), so the probability check in
/// the transcriber misses them — the text itself has to be rejected.
///
/// Two match classes:
///  - **Phrases** — exact match after normalization. The thank-you /
///    thanks-for-watching family per language. Deliberate tradeoff (same as
///    the original English-only list): a genuine lone "Merci." dictation is
///    sacrificed to kill the #1 silence artifact in that language. Only the
///    most-reported artifacts are listed; anything a user plausibly dictates
///    as part of a longer sentence is unaffected (matching is whole-text).
///  - **Markers** — substring match for caption-credit artifacts whose wording
///    varies around a stable core (site names, broadcaster credits, subtitler
///    sign-offs) and which never occur in real dictation.
///
/// Covers the languages offered in Settings (en/es/he/fr/de/pt/zh) plus the
/// most notorious auto-detect artifacts (ja/ko/it/ru/ar).
enum HallucinationFilter {
    static func isLikelySilenceHallucination(_ text: String) -> Bool {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return false }
        if phrases.contains(normalized) { return true }
        return markers.contains { normalized.contains($0) }
    }

    /// Lowercase, fold the typographic apostrophe to ASCII, collapse internal
    /// whitespace, and strip edge punctuation / symbols (incl. CJK 。！？ and
    /// inverted ¡¿) and bidi marks — so "¡Gracias!", "gracias.", and "Gracias"
    /// all normalize identically.
    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: edgeTrim)
    }

    private static let edgeTrim: CharacterSet = .whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(.symbols)
        .union(CharacterSet(charactersIn: "\u{200E}\u{200F}"))  // LRM/RLM bidi marks

    private static let phrases: Set<String> = [
        // English
        "thank you",
        "thank you very much",
        "thank you so much",
        "thanks for watching",
        "thank you for watching",
        "thank you so much for watching",
        // Spanish
        "gracias",
        "muchas gracias",
        "gracias por ver",
        "gracias por ver el video",
        "gracias por ver el vídeo",
        "gracias por su atención",
        // French
        "merci",
        "merci beaucoup",
        "merci d'avoir regardé",
        "merci d'avoir regardé cette vidéo",
        "merci à tous",
        "n'oubliez pas de vous abonner",
        // German
        "danke",
        "danke schön",
        "dankeschön",
        "vielen dank",
        "danke fürs zuschauen",
        "vielen dank fürs zuschauen",
        // Portuguese
        "obrigado",
        "obrigada",
        "muito obrigado",
        "muito obrigada",
        "obrigado por assistir",
        "obrigada por assistir",
        // Hebrew
        "תודה",
        "תודה רבה",
        "תודה שצפיתם",
        "תודה על הצפייה",
        // Chinese (simplified + traditional)
        "谢谢",
        "謝謝",
        "谢谢大家",
        "謝謝大家",
        "谢谢观看",
        "謝謝觀看",
        "谢谢收看",
        "謝謝收看",
        "感谢观看",
        "感謝觀看",
        // Japanese
        "ありがとうございます",
        "ありがとうございました",
        "ご視聴ありがとうございます",
        "ご視聴ありがとうございました",
        "チャンネル登録お願いします",
        "チャンネル登録をお願いします",
        // Korean
        "감사합니다",
        "시청해 주셔서 감사합니다",
        "시청해주셔서 감사합니다",
        "구독과 좋아요 부탁드립니다",
        // Italian
        "grazie",
        "grazie mille",
        "grazie a tutti",
        "grazie per aver guardato",
        // Russian
        "спасибо",
        "спасибо за просмотр",
        "благодарю за просмотр",
        // Arabic (with and without final tanween)
        "شكرا",
        "شكراً",
        "شكرًا",
        "شكرا لكم",
        "شكرا على المشاهدة",
    ]

    /// Lowercase substrings that mark caption-credit artifacts.
    private static let markers: [String] = [
        "amara.org",                     // "Subtitles by the Amara.org community" (all languages)
        "opensubtitles.org",
        "untertitelung des zdf",         // German broadcaster credits, e.g. "… des ZDF, 2020"
        "untertitel im auftrag des zdf",
        "sous-titrage st'",              // French TV credit "Sous-titrage ST' 501"
        "société radio-canada",          // "sous-titrage société radio-canada"
        "明镜与点点",                     // "请不吝点赞订阅转发打赏支持明镜与点点栏目"
        "明鏡與點點",
        "dimatorzok",                    // Russian "Субтитры сделал DimaTorzok"
        "نانسي قنقر",                    // Arabic "ترجمة نانسي قنقر"
        "a cura di qtss",                // Italian "Sottotitoli e revisione a cura di QTSS"
    ]
}
