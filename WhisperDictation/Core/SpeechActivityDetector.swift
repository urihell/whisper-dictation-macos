import Foundation
import AVFoundation
import SoundAnalysis

/// Detects whether human speech is present in the mic stream using Apple's
/// on-device SoundAnalysis classifier ("speech" category). Loudness-independent,
/// so it recognizes quiet speech that an energy threshold can't separate from
/// silence.
///
/// Two consumers:
///  - session suppression (`everSpeech` via the transcriber's `vadSuppresses`):
///    a session the classifier is confident contained no speech is discarded;
///  - time-aligned confirmation (`sawSpeech(betweenSeconds:and:)`): the
///    classifier windows share the session-audio clock with Whisper's segment
///    timestamps (both count 16 kHz samples from session start), so the
///    transcriber can check whether a hallucination-phrase suspect like a lone
///    "Thank you" had real speech under it — spoken, not hallucinated.
// @unchecked Sendable: all mutable state is guarded by `lock`, and analysis is
// serialized on `analysisQueue` — so an instance can be built on a background
// task (its init does a one-time, potentially slow Core ML/ANE load) and then
// handed to the main actor without data races.
final class SpeechActivityDetector: NSObject, SNResultsObserving, @unchecked Sendable {
    private let analyzer: SNAudioStreamAnalyzer
    private let format: AVAudioFormat
    private let analysisQueue = DispatchQueue(label: "com.udabby.WhisperDictation.vad")
    private var framePosition: AVAudioFramePosition = 0

    private let lock = NSLock()
    private var _everSpeech = false
    private var _maxSpeechConfidence: Double = 0
    private var _resultCount = 0
    private var _lastTopLabel = ""
    /// Analysis windows (seconds in session audio) where speech was detected.
    /// One entry per ~1s classifier window, so this stays small even for long
    /// dictations.
    private var _speechIntervals: [(start: Double, end: Double)] = []

    /// Confidence at/above which we consider "speech" present.
    static let speechThreshold: Double = 0.3

    init?(sampleRate: Double = 16_000) {
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: sampleRate,
                                      channels: 1,
                                      interleaved: false) else { return nil }
        format = fmt
        analyzer = SNAudioStreamAnalyzer(format: fmt)
        super.init()
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            try analyzer.add(request, withObserver: self)
        } catch {
            Log.error("VAD: SoundAnalysis setup failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Feed newly-captured mono 16 kHz samples.
    func analyze(_ samples: [Float]) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { channel[0].update(from: base, count: samples.count) }
        }
        let pos = framePosition
        framePosition += AVAudioFramePosition(samples.count)
        analysisQueue.async { [weak self] in
            self?.analyzer.analyze(buffer, atAudioFramePosition: pos)
        }
    }

    var everSpeech: Bool { lock.withLock { _everSpeech } }
    var maxSpeechConfidence: Double { lock.withLock { _maxSpeechConfidence } }
    var resultCount: Int { lock.withLock { _resultCount } }

    /// Whether the classifier saw speech in a window overlapping `start...end`
    /// (seconds in session audio). `tolerance` pads both sides: Whisper's
    /// segment timestamps and the ~1s analysis windows are both approximate, so
    /// a strict overlap would miss speech right at a segment edge.
    func sawSpeech(betweenSeconds start: Double, and end: Double, tolerance: Double = 0.5) -> Bool {
        let lo = start - tolerance
        let hi = end + tolerance
        return lock.withLock {
            _speechIntervals.contains { $0.start < hi && $0.end > lo }
        }
    }

    /// One-line summary for diagnostics/calibration.
    var stats: String {
        lock.withLock {
            "everSpeech=\(_everSpeech), maxSpeechConf=\(String(format: "%.2f", _maxSpeechConfidence)), results=\(_resultCount), speechWindows=\(_speechIntervals.count), top=\(_lastTopLabel)"
        }
    }

    // MARK: - SNResultsObserving
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let speechConf = result.classification(forIdentifier: "speech")?.confidence ?? 0
        let top = result.classifications.first?.identifier ?? ""
        // The result's window is on the session-audio clock because analyze()
        // positions buffers by absolute frame at the format's sample rate.
        let window = result.timeRange
        lock.withLock {
            _resultCount += 1
            _lastTopLabel = top
            if speechConf > _maxSpeechConfidence { _maxSpeechConfidence = speechConf }
            if speechConf >= Self.speechThreshold {
                _everSpeech = true
                _speechIntervals.append((window.start.seconds, window.end.seconds))
            }
        }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        Log.error("VAD: analysis failed: \(error.localizedDescription)")
    }

    func requestDidComplete(_ request: SNRequest) {}
}
