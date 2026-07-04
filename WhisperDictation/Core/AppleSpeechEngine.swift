import Foundation
import AVFoundation
import CoreMedia
import Speech
import WhisperKit

/// Errors from the Apple Speech engine. Defined outside the availability-gated
/// class so DictationController can catch them on any OS (its fallback-to-
/// Whisper path pattern-matches on `.localeUnsupported`).
enum AppleSpeechEngineError: LocalizedError {
    case localeUnsupported
    case audioFormatUnavailable

    var errorDescription: String? {
        switch self {
        case .localeUnsupported:
            return "Apple Speech doesn't support this language on this Mac."
        case .audioFormatUnavailable:
            return "Apple Speech couldn't provide an audio format."
        }
    }
}

/// Dictation engine backed by Apple's SpeechAnalyzer (macOS 26+): starts
/// instantly, downloads only small per-language assets on first use, and runs
/// far cooler than Whisper — at the cost of supporting fewer languages.
///
/// Design decisions:
///  - Capture reuses `SelectableInputAudioProcessor` (plain path + the same
///    device-selection/VPIO policy as Whisper), so all the hard-won audio
///    lessons (TCC pre-flight, Bluetooth double-open, VPIO fallback — see
///    tasks/lessons.md) apply unchanged. 16 kHz mono floats are wrapped into
///    PCM buffers (resampled if the analyzer prefers another format) and fed
///    to the analyzer's input stream.
///  - No warm-idle: the analyzer itself has no meaningful cold start, so
///    sessions are built and torn down whole.
///  - No hallucination filter / VAD suppression: those exist for Whisper's
///    silence-hallucination behavior, which this engine doesn't share.
///  - Volatile results drive the live HUD; finalized results accumulate into
///    the transcript and feed the incremental cleanup pipeline.
@available(macOS 26.0, *)
@MainActor
final class AppleSpeechEngine: DictationEngine {
    var onStreamError: ((Error) -> Void)?
    var onConfirmedText: ((String) -> Void)?
    private(set) var lastSessionCapturedAudio = true
    /// Apple's transcriber doesn't hallucinate on silence — never suppress.
    let lastSessionSuppressedNonSpeech = false

    /// Per-session input-device override (per-app profile); see DictationEngine.
    var inputDeviceUIDOverride: String?

    var activeInputDeviceName: String? {
        SelectableInputAudioProcessor.captureDeviceName(overridingUID: inputDeviceUIDOverride)
    }

    /// Same battle-tested capture stack as the Whisper path.
    private let processor = SelectableInputAudioProcessor()

    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var finalizedText = ""
    private var volatileText = ""
    private var capturedSamples = 0

    /// Session token given to each start(); guards resumption after awaits.
    private var currentSession = 0
    /// Results from sessions below this are dropped (forceStop invalidates the
    /// session outright; stop() only raises this AFTER draining finals, so the
    /// last words are never discarded).
    private var invalidBefore = 0

    func start(language: String?) async throws {
        if analyzer != nil { forceStop() }   // defensive: never two sessions
        currentSession += 1
        let token = currentSession
        finalizedText = ""
        volatileText = ""
        capturedSamples = 0
        lastSessionCapturedAudio = true
        // Clear the previous session's text/meter from the HUD, exactly like
        // the Whisper path does — otherwise the old transcript lingers until
        // the first new result lands.
        HUDLiveState.shared.resetForSession()

        // A specific language is required: this transcriber is single-locale
        // per session, so "auto" must be handled by Whisper (the controller
        // routes it there; this guard is the defensive backstop).
        guard let language else {
            throw AppleSpeechEngineError.localeUnsupported
        }
        // Standard vs dictation-tuned module (experimental Settings toggle).
        // Each has its own Result type, so the results pump is prepared
        // alongside the module and started only after the guards below pass.
        let module: any SpeechModule
        let localeID: String
        let startResultsPump: () -> Void
        if AppSettings.shared.appleDictationModel {
            guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
                throw AppleSpeechEngineError.localeUnsupported
            }
            let dictation = DictationTranscriber(
                locale: locale,
                contentHints: [],
                transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults, .frequentFinalization],
                attributeOptions: []
            )
            module = dictation
            localeID = locale.identifier
            startResultsPump = { [weak self] in
                guard let self else { return }
                self.resultsTask = self.startPump(dictation.results, token: token) {
                    (String($0.text.characters), $0.isFinal)
                }
            }
        } else {
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
                throw AppleSpeechEngineError.localeUnsupported
            }
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: []
            )
            module = transcriber
            localeID = locale.identifier
            startResultsPump = { [weak self] in
                guard let self else { return }
                self.resultsTask = self.startPump(transcriber.results, token: token) {
                    (String($0.text.characters), $0.isFinal)
                }
            }
        }
        guard token == currentSession else { return }

        // First use of a language downloads its assets (small; nothing like a
        // Whisper model). No-op when already installed — and Settings
        // pre-downloads when the engine/language is picked, so a session
        // rarely pays this.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            Log.info("AppleSpeech: downloading assets for \(localeID)…")
            try await request.downloadAndInstall()
            Log.info("AppleSpeech: assets installed.")
        }
        guard token == currentSession else { return }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw AppleSpeechEngineError.audioFormatUnavailable
        }
        guard token == currentSession else { return }

        // The capture stack delivers 16 kHz mono Float32; resample only if the
        // analyzer wants something else.
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(WhisperKit.sampleRate),
            channels: 1,
            interleaved: false
        ) else { throw AppleSpeechEngineError.audioFormatUnavailable }
        let needsConversion = analyzerFormat.sampleRate != sourceFormat.sampleRate
            || analyzerFormat.channelCount != sourceFormat.channelCount
            || analyzerFormat.commonFormat != sourceFormat.commonFormat
        let converter = needsConversion ? AVAudioConverter(from: sourceFormat, to: analyzerFormat) : nil
        Log.info("AppleSpeech: locale=\(localeID), model=\(AppSettings.shared.appleDictationModel ? "dictation" : "standard"), analyzer wants \(Int(analyzerFormat.sampleRate)) Hz/\(analyzerFormat.channelCount)ch\(needsConversion ? " (resampling from 16 kHz mono)" : "")")

        let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation
        let analyzer = SpeechAnalyzer(modules: [module])
        self.analyzer = analyzer

        // Results pump: volatile → live HUD; final → transcript + cleanup feed.
        startResultsPump()

        try await analyzer.start(inputSequence: inputStream)
        guard token == currentSession else { return }

        // Same device + voice-processing policy as the Whisper path; never
        // warm-idle (nothing here has a cold start worth amortizing). A
        // per-app override ("" = system default) replaces the global setting.
        let uid = inputDeviceUIDOverride ?? AppSettings.shared.audioInputDeviceUID
        let device: DeviceID? = uid.isEmpty ? nil : SelectableInputAudioProcessor.deviceID(forUID: uid)
        processor.selectedDeviceID = device
        processor.voiceIsolationEnabled = SelectableInputAudioProcessor.shouldEngageVoiceProcessing(forInputDevice: device)
        processor.keepWarmOnStop = false

        try processor.startRecordingLive(inputDeviceID: device) { [weak self] samples in
            // Real-time tap thread: wrap (and if needed resample) the chunk,
            // hand it to the analyzer, hop to the main actor only for
            // bookkeeping and the level meter.
            guard var buffer = Self.pcmBuffer(from: samples, format: sourceFormat) else { return }
            if let converter,
               let converted = Self.convert(buffer, with: converter, to: analyzerFormat) {
                buffer = converted
            }
            continuation.yield(AnalyzerInput(buffer: buffer))
            let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
            let count = samples.count
            Task { @MainActor [weak self] in self?.noteCaptured(count: count, peak: peak) }
        }

        // Honest "go" cue, mirroring the Whisper path: don't return (and let
        // the controller chime) until audio actually flows, ~2s backstop.
        for _ in 0..<100 {
            guard token == currentSession else { return }
            if capturedSamples > 0 {
                Log.info("AppleSpeech: mic live — first buffer captured.")
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        Log.info("AppleSpeech: mic warm-up wait timed out (~2s) — proceeding.")
    }

    func stop() async -> String {
        let token = currentSession
        currentSession += 1   // supersede any start() still mid-await
        processor.stopRecording()
        inputContinuation?.finish()
        inputContinuation = nil
        lastSessionCapturedAudio = capturedSamples >= Int(Double(WhisperKit.sampleRate) * 0.25)

        // Drain: finalize whatever audio is still in flight, then wait for the
        // results stream to end so the last finalized words are collected.
        // (Awaiting suspends the main actor, so ingest() can still hop on.)
        if let analyzer {
            do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
            catch { Log.error("AppleSpeech: finalize failed: \(error.localizedDescription)") }
        }
        await resultsTask?.value
        resultsTask = nil
        analyzer = nil
        invalidBefore = currentSession   // block any stragglers from now on
        _ = token
        HUDLiveState.shared.audioLevel = 0

        let text = SentenceChunking.normalize(finalizedText)
        Log.info("AppleSpeech: stop() — \(text.count) chars finalized.")
        guard !text.isEmpty else { return "" }
        return ReplacementEngine.apply(text, rules: AppSettings.shared.replacements)
    }

    func forceStop() {
        currentSession += 1
        invalidBefore = currentSession   // discard everything from the session
        processor.stopRecording()
        inputContinuation?.finish()
        inputContinuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        HUDLiveState.shared.audioLevel = 0
    }

    // MARK: - Results

    /// Shared results pump: both module types stream Result values whose text
    /// and finality are pulled out by `extract`.
    private func startPump<S: AsyncSequence & Sendable>(
        _ results: S,
        token: Int,
        extract: @escaping (S.Element) -> (String, Bool)
    ) -> Task<Void, Never> where S.Element: Sendable {
        Task { [weak self] in
            do {
                for try await result in results {
                    let (text, isFinal) = extract(result)
                    await MainActor.run { self?.ingest(text: text, isFinal: isFinal, token: token) }
                }
            } catch {
                Log.error("AppleSpeech: results stream error: \(error.localizedDescription)")
                await MainActor.run {
                    guard let self, token == self.currentSession else { return }
                    self.onStreamError?(error)
                }
            }
        }
    }

    /// Download the assets for `languageCode` in the background so the first
    /// real session doesn't pay the download at dictation start. Called from
    /// Settings when the engine/language/model changes, and at launch.
    /// Fire-and-forget; failures only log (the session-start path retries).
    static func preinstallAssets(languageCode: String?) {
        guard let languageCode else { return }   // auto → Whisper, nothing to fetch
        Task { @MainActor in
            do {
                let module: any SpeechModule
                if AppSettings.shared.appleDictationModel {
                    guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: languageCode)) else { return }
                    module = DictationTranscriber(
                        locale: locale, contentHints: [],
                        transcriptionOptions: [.punctuation],
                        reportingOptions: [.volatileResults, .frequentFinalization],
                        attributeOptions: []
                    )
                } else {
                    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: languageCode)) else { return }
                    module = SpeechTranscriber(
                        locale: locale, transcriptionOptions: [],
                        reportingOptions: [.volatileResults, .fastResults],
                        attributeOptions: []
                    )
                }
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    Log.info("AppleSpeech: pre-downloading assets for \(languageCode)…")
                    try await request.downloadAndInstall()
                    Log.info("AppleSpeech: assets ready for \(languageCode).")
                }
            } catch {
                Log.error("AppleSpeech: asset pre-download failed: \(error.localizedDescription)")
            }
        }
    }

    private func ingest(text: String, isFinal: Bool, token: Int) {
        guard token >= invalidBefore else { return }   // cancelled session
        if isFinal {
            finalizedText += text
            volatileText = ""
            let confirmed = SentenceChunking.normalize(finalizedText)
            if !confirmed.isEmpty { onConfirmedText?(confirmed) }
        } else {
            volatileText = text
        }
        HUDLiveState.shared.liveText = SentenceChunking.normalize(finalizedText + volatileText)
    }

    private func noteCaptured(count: Int, peak: Float) {
        capturedSamples += count
        let live = HUDLiveState.shared
        let level = min(1, peak * 3)   // peak amplitude ≈ meter drive
        live.audioLevel = live.audioLevel * 0.6 + level * 0.4
    }

    // MARK: - Buffer plumbing (tap thread)

    nonisolated private static func pcmBuffer(from samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { channel[0].update(from: base, count: samples.count) }
        }
        return buffer
    }

    /// Streaming-safe conversion: the converter is reused across chunks (it
    /// keeps resampler state), each call feeding exactly one input buffer.
    nonisolated private static func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var error: NSError?
        var served = false
        converter.convert(to: out, error: &error) { _, status in
            if served {
                status.pointee = .noDataNow
                return nil
            }
            served = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            Log.error("AppleSpeech: resample failed: \(error.localizedDescription)")
            return nil
        }
        return out
    }
}
