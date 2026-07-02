import Foundation

/// Pure sentence-boundary logic for the incremental cleanup pipeline —
/// extracted from `IncrementalCleaner` so it can be unit-tested without
/// dragging in the model/settings dependencies.
enum SentenceChunking {
    /// Index just past the sentence-ender of the SECOND-newest complete
    /// sentence in `text` — i.e. everything chunkable while holding back the
    /// newest complete sentence as the self-correction buffer. Nil when fewer
    /// than two complete sentences exist.
    static func holdBackCut(in text: String) -> String.Index? {
        var enders: [String.Index] = []
        var i = text.startIndex
        while i < text.endIndex {
            if ".!?…".contains(text[i]) {
                let next = text.index(after: i)
                // Real sentence end: followed by whitespace (or nothing —
                // but a trailing ender stays in the hold-back).
                if next < text.endIndex, text[next].isWhitespace {
                    enders.append(next)
                }
            }
            i = text.index(after: i)
        }
        guard enders.count >= 2 else { return nil }
        return enders[enders.count - 2]
    }

    /// Whitespace-collapse + trim, mirroring how the transcriber's `clean`
    /// normalizes spacing — so prefix comparison isn't defeated by run-of-
    /// spaces differences between the streamed and final text.
    static func normalize(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
