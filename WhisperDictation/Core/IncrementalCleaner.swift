import Foundation

/// Cleans the transcript in the background WHILE the user is still dictating,
/// so the end-of-dictation wait shrinks from "clean everything" to "clean the
/// last sentence or two".
///
/// How: as Whisper confirms (locks) segments, complete sentences are batched
/// and sent to the on-device model one chunk at a time — always holding back
/// the most recent complete sentence, since a self-correction usually follows
/// immediately ("…at five. No, at six."). At stop, `finish` waits for the
/// in-flight chunk, cleans only the remaining tail (streaming it to the HUD),
/// and stitches the pieces together.
///
/// Safety: the stitched result is only used when the final transcript still
/// starts with exactly the text that was chunk-cleaned. If anything diverged —
/// a late-admitted segment, a replacement spanning a chunk boundary, tail
/// re-decode differences — `finish` falls back to cleaning the whole final
/// text in one call, which is exactly today's behavior. Known tradeoff: a
/// self-correction that spans a chunk boundary is cleaned per-chunk and may
/// slip through unfixed.
@MainActor
final class IncrementalCleaner {
    private let languageHint: String?

    /// Cleaned results, in order, for the chunks sent so far.
    private var cleanedChunks: [String] = []
    /// The raw confirmed text consumed so far (normalized, pre-replacement) —
    /// the high-water mark for `ingest`.
    private var consumedRaw = ""
    /// The replacement-applied, normalized text the chunks were built from.
    /// `finish` requires the final transcript to start with exactly this before
    /// trusting the stitched prefix.
    private var sentBasis = ""
    private var worker: Task<Void, Never>?
    private var cancelled = false
    /// Set when the confirmed stream changed behind the high-water mark; all
    /// further chunking stops and `finish` falls back to a whole-text clean.
    private var diverged = false

    /// Don't bother the model with less than this — each call has a fixed
    /// multi-second cost, so tiny chunks waste it.
    private static let minChunkChars = 80

    init(languageHint: String?) {
        self.languageHint = languageHint
    }

    /// Feed the latest confirmed (locked) transcript. Called on every confirmed
    /// update while recording; cheap unless a new chunk is ready AND the worker
    /// is free — text that arrives while a chunk is cleaning simply waits and
    /// ships in the next, bigger chunk (no queue to back up).
    func ingest(confirmed rawConfirmed: String) {
        guard !cancelled, !diverged, worker == nil else { return }
        let confirmed = Self.normalize(rawConfirmed)
        guard confirmed.hasPrefix(consumedRaw) else {
            // Confirmed segments are locked so the stream should only append;
            // a change behind the high-water mark means the segment filter
            // re-admitted something late. Stop chunking — finish() will fall
            // back to the whole-text clean.
            diverged = true
            Log.info("IncrementalCleaner: confirmed stream diverged; falling back to whole-text cleanup at stop.")
            return
        }
        let unconsumed = String(confirmed.dropFirst(consumedRaw.count))

        // Chunk = complete sentences, minus the newest one (the hold-back).
        guard let cut = Self.holdBackCut(in: unconsumed) else { return }
        let candidate = String(unconsumed[..<cut]).trimmingCharacters(in: .whitespaces)
        guard candidate.count >= Self.minChunkChars else { return }

        consumedRaw += String(unconsumed[..<cut])
        let chunk = ReplacementEngine.apply(candidate, rules: AppSettings.shared.replacements)
        sentBasis = sentBasis.isEmpty ? chunk : sentBasis + " " + chunk
        worker = Task { [weak self, languageHint] in
            let cleaned = await SpeechCleaner.clean(chunk, languageHint: languageHint)
            guard let self, !self.cancelled else { return }
            self.cleanedChunks.append(cleaned)
            self.worker = nil
            Log.info("IncrementalCleaner: chunk cleaned in background (\(chunk.count) → \(cleaned.count) chars, \(self.cleanedChunks.count) total)")
        }
    }

    /// Discard everything (Escape / error). The in-flight model call can't be
    /// interrupted, but its result is dropped.
    func cancel() {
        cancelled = true
        worker?.cancel()
        worker = nil
    }

    /// Produce the final cleaned text for `finalText` (the transcriber's
    /// finished transcript, replacements applied). Streams progress into
    /// `onPartial` for the HUD. Falls back to a single whole-text clean when
    /// no chunks exist or the prefix no longer matches.
    func finish(finalText: String, onPartial: @escaping (String) -> Void) async -> String {
        // Wait for the in-flight chunk (at most one; ingest never queues more).
        if let w = worker { await w.value }

        let prefix = cleanedChunks.joined(separator: " ")
        let normFinal = Self.normalize(finalText)

        guard !prefix.isEmpty, !diverged, normFinal.hasPrefix(sentBasis) else {
            if !prefix.isEmpty {
                Log.info("IncrementalCleaner: prefix mismatch — cleaning whole text instead.")
            }
            return await SpeechCleaner.clean(finalText, languageHint: languageHint, onPartial: onPartial)
        }

        let remainder = String(normFinal.dropFirst(sentBasis.count))
            .trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else {
            Log.info("IncrementalCleaner: all text pre-cleaned — instant finish.")
            return prefix
        }

        // Show the already-cleaned prefix immediately, then stream the tail in.
        onPartial(prefix)
        let cleanedTail = await SpeechCleaner.clean(remainder, languageHint: languageHint) { partial in
            onPartial(partial.isEmpty ? prefix : prefix + " " + partial)
        }
        Log.info("IncrementalCleaner: finished — \(cleanedChunks.count) pre-cleaned chunks + \(remainder.count)-char tail.")
        return cleanedTail.isEmpty ? prefix : prefix + " " + cleanedTail
    }

    /// Index just past the sentence-ender of the SECOND-newest complete
    /// sentence in `text` — i.e. everything chunkable while holding back the
    /// newest complete sentence as the self-correction buffer. Nil when fewer
    /// than two complete sentences exist.
    private static func holdBackCut(in text: String) -> String.Index? {
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
    private static func normalize(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
