import Foundation
import AVFoundation
import SoundAnalysis

/// Detects whether human speech is present in the mic stream using Apple's
/// on-device SoundAnalysis classifier ("speech" category). Loudness-independent,
/// so it recognizes quiet speech that an energy threshold can't separate from
/// silence.
///
/// Currently instrumentation-only: it reports detection stats (via `stats`) so
/// we can verify reliability against this mic before gating any transcript on it.
final class SpeechActivityDetector: NSObject, SNResultsObserving {
    private let analyzer: SNAudioStreamAnalyzer
    private let format: AVAudioFormat
    private let analysisQueue = DispatchQueue(label: "com.udabby.WhisperDictation.vad")
    private var framePosition: AVAudioFramePosition = 0

    private let lock = NSLock()
    private var _everSpeech = false
    private var _maxSpeechConfidence: Double = 0
    private var _resultCount = 0
    private var _lastTopLabel = ""

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

    /// One-line summary for diagnostics/calibration.
    var stats: String {
        lock.withLock {
            "everSpeech=\(_everSpeech), maxSpeechConf=\(String(format: "%.2f", _maxSpeechConfidence)), results=\(_resultCount), top=\(_lastTopLabel)"
        }
    }

    // MARK: - SNResultsObserving
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let speechConf = result.classification(forIdentifier: "speech")?.confidence ?? 0
        let top = result.classifications.first?.identifier ?? ""
        lock.withLock {
            _resultCount += 1
            _lastTopLabel = top
            if speechConf > _maxSpeechConfidence { _maxSpeechConfidence = speechConf }
            if speechConf >= Self.speechThreshold { _everSpeech = true }
        }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        Log.error("VAD: analysis failed: \(error.localizedDescription)")
    }

    func requestDidComplete(_ request: SNRequest) {}
}
