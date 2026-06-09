import Foundation
import AVFoundation
import AudioToolbox
import CoreML
import WhisperKit

/// An `AudioProcessing` decorator that records from a user-chosen input device,
/// optionally through Apple's Voice Processing I/O for background-noise removal.
///
/// WhisperKit's `AudioStreamTranscriber` always starts recording with the default
/// (nil) device and exposes no way to pass one, and the real `AudioProcessor`
/// method that takes a device id isn't `open` — so we can't subclass-override it.
/// Instead we wrap a real `AudioProcessor` and, whenever a caller asks for the
/// default device (nil), substitute the user's `selectedDeviceID`. Everything
/// reads through to the wrapped instance (`audioSamples`, `relativeEnergy`, …).
///
/// When `voiceIsolationEnabled` is on we go a step further and run our OWN
/// `AVAudioEngine`: WhisperKit's `setupEngine()` installs its tap and starts the
/// engine in one internal call, but Voice Processing must be enabled on the input
/// node *before* the engine starts — there's no public seam to inject it. So we
/// build the capture graph ourselves with `setVoiceProcessingEnabled(true)` and
/// feed the (resampled, isolated) samples back into the wrapped processor's
/// public buffers, exactly the way its private `processBuffer` would. When
/// isolation is off we forward to the wrapped processor unchanged — the original,
/// proven path with zero behavior change.
final class SelectableInputAudioProcessor: AudioProcessing, @unchecked Sendable {
    /// Core Audio input device to capture from, or nil for the system default.
    var selectedDeviceID: DeviceID?

    /// Route mic input through Voice Processing I/O (noise/echo suppression).
    /// Read once at `startRecordingLive`; changing it mid-session has no effect.
    var voiceIsolationEnabled = false

    /// The real processor doing all the work (and holding the buffers the
    /// streaming transcriber polls).
    let inner = AudioProcessor()

    /// Our own capture engine, live only while isolation is on. nil otherwise
    /// (the wrapped processor owns the engine on the forwarded path).
    private var isolationEngine: AVAudioEngine?
    /// The streamer's per-buffer callback, retained while isolation drives capture.
    private var isolationCallback: (([Float]) -> Void)?

    // MARK: - Device injection / Voice-Isolation capture

    func startRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        let device = inputDeviceID ?? selectedDeviceID
        guard voiceIsolationEnabled else {
            try inner.startRecordingLive(inputDeviceID: device, callback: callback)
            return
        }
        try startIsolatedRecording(inputDeviceID: device, callback: callback)
    }

    func startStreamingRecordingLive(inputDeviceID: DeviceID?) -> (AsyncThrowingStream<[Float], Error>, AsyncThrowingStream<[Float], Error>.Continuation) {
        // Streaming-stream API isn't used by this app's transcriber (it uses the
        // callback form above), so leave it on the wrapped processor's default
        // path — Voice Isolation only needs to cover the path we actually drive.
        inner.startStreamingRecordingLive(inputDeviceID: inputDeviceID ?? selectedDeviceID)
    }

    func resumeRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        let device = inputDeviceID ?? selectedDeviceID
        guard voiceIsolationEnabled else {
            try inner.resumeRecordingLive(inputDeviceID: device, callback: callback)
            return
        }
        // Our engine is fully torn down on stop, so resume just rebuilds it.
        try startIsolatedRecording(inputDeviceID: device, callback: callback)
    }

    /// Builds a Voice-Processing capture engine and pumps isolated 16 kHz mono
    /// samples into `inner`'s public buffers (mirroring its private `processBuffer`),
    /// so everything downstream — the streamer's polling of `audioSamples` /
    /// `relativeEnergy` and the per-buffer callback — works unchanged.
    private func startIsolatedRecording(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        // Match AudioProcessor.startRecordingLive: clear prior session state.
        inner.audioSamples = []
        inner.audioEnergy = []
        isolationCallback = callback

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Enable Voice Processing (AEC + noise suppression + non-voice ducking)
        // BEFORE the engine starts — the whole reason we own this graph.
        try inputNode.setVoiceProcessingEnabled(true)

        // Honor an explicit input-device selection if possible. Voice Processing
        // manages its own aggregate device, so this may be ignored or fail — we
        // try and tolerate it, falling back to the system default mic (the UI
        // copy states this caveat).
        if let inputDeviceID, let audioUnit = inputNode.audioUnit {
            var dev = inputDeviceID
            let err = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &dev,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if err != noErr {
                Log.info("Voice Isolation: couldn't pin input device (\(err)); using system default.")
            }
        }

        // Down to Whisper's 16 kHz mono. Voice Processing presents the input as a
        // DISCRETE multichannel layout (measured: 9 identical channels @ 48 kHz,
        // layoutTag kAudioChannelLayoutTag_DiscreteInOrder). AVAudioConverter
        // CANNOT downmix a discrete layout to mono — it silently outputs zeros
        // (verified), which is why audio appeared "dead". The channels are
        // duplicates, each carrying the full signal, so we extract channel 0 into
        // a standard mono buffer at the node's rate, then let the converter do the
        // mono→16 kHz resample (a layout it handles correctly, at unity gain).
        let nodeFormat = inputNode.outputFormat(forBus: 0)
        guard let monoNodeFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                 sampleRate: nodeFormat.sampleRate,
                                                 channels: 1,
                                                 interleaved: false),
              let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: Double(WhisperKit.sampleRate),
                                                channels: 1,
                                                interleaved: false),
              let converter = AVAudioConverter(from: monoNodeFormat, to: desiredFormat) else {
            try? inputNode.setVoiceProcessingEnabled(false)
            throw WhisperError.audioProcessingFailed("Voice Isolation: failed to build audio format/converter")
        }

        let bufferSize = AVAudioFrameCount(inner.minBufferLength) // 100–400ms
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: nodeFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // Copy channel 0 into a mono buffer (avoids the broken discrete downmix).
            guard let src = buffer.floatChannelData,
                  let mono = AVAudioPCMBuffer(pcmFormat: monoNodeFormat,
                                              frameCapacity: buffer.frameLength) else { return }
            mono.frameLength = buffer.frameLength
            mono.floatChannelData![0].update(from: src[0], count: Int(buffer.frameLength))

            var out = mono
            if !monoNodeFormat.sampleRate.isEqual(to: Double(WhisperKit.sampleRate)) {
                do {
                    out = try AudioProcessor.resampleBuffer(mono, with: converter)
                } catch {
                    Log.error("Voice Isolation: resample failed: \(error.localizedDescription)")
                    return
                }
            }
            let samples = AudioProcessor.convertBufferToArray(buffer: out)
            self.ingest(samples)
        }

        engine.prepare()
        try engine.start()
        isolationEngine = engine
        Log.info("Voice Isolation: capture engine started (\(Int(nodeFormat.sampleRate)) Hz / \(nodeFormat.channelCount) ch → 16 kHz mono).")
    }

    /// Appends an isolated 16 kHz buffer to `inner`'s public buffers and fires the
    /// streamer's callback — a faithful copy of `AudioProcessor.processBuffer`.
    private func ingest(_ buffer: [Float]) {
        guard !buffer.isEmpty else { return }
        inner.audioSamples.append(contentsOf: buffer)
        let minAvgEnergy = inner.audioEnergy.suffix(20).reduce(Float.infinity) { min($0, $1.avg) }
        let relativeEnergy = AudioProcessor.calculateRelativeEnergy(of: buffer, relativeTo: minAvgEnergy)
        let signalEnergy = AudioProcessor.calculateEnergy(of: buffer)
        inner.audioEnergy.append((relativeEnergy, signalEnergy.avg, signalEnergy.max, signalEnergy.min))
        isolationCallback?(buffer)
    }

    /// Tears down our Voice-Processing engine if we own one. Mirrors
    /// AudioProcessor.stopRecording's thorough graph teardown so repeated
    /// start/stop cycles don't leak input connections.
    private func teardownIsolationEngine() {
        guard let engine = isolationEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.attachedNodes.forEach { $0.removeTap(onBus: 0) }
        // Turn Voice Processing back off so the node/device returns to normal.
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        engine.disconnectNodeInput(engine.inputNode)
        engine.stop()
        engine.reset()
        isolationEngine = nil
        isolationCallback = nil
    }

    // MARK: - Straight passthrough

    var audioSamples: ContiguousArray<Float> { inner.audioSamples }
    var relativeEnergy: [Float] { inner.relativeEnergy }
    var relativeEnergyWindow: Int {
        get { inner.relativeEnergyWindow }
        set { inner.relativeEnergyWindow = newValue }
    }
    func purgeAudioSamples(keepingLast keep: Int) { inner.purgeAudioSamples(keepingLast: keep) }
    func pauseRecording() {
        if isolationEngine != nil { isolationEngine?.pause() } else { inner.pauseRecording() }
    }
    func stopRecording() {
        if isolationEngine != nil { teardownIsolationEngine() } else { inner.stopRecording() }
    }
    func padOrTrim(fromArray audioArray: [Float], startAt startIndex: Int, toLength frameLength: Int) -> (any AudioProcessorOutputType)? {
        inner.padOrTrim(fromArray: audioArray, startAt: startIndex, toLength: frameLength)
    }

    // MARK: - Static passthrough

    static func loadAudio(fromPath audioFilePath: String, channelMode: AudioInputConfig.ChannelMode, startTime: Double?, endTime: Double?, maxReadFrameSize: AVAudioFrameCount?) throws -> AVAudioPCMBuffer {
        try AudioProcessor.loadAudio(fromPath: audioFilePath, channelMode: channelMode, startTime: startTime, endTime: endTime, maxReadFrameSize: maxReadFrameSize)
    }

    static func loadAudio(at audioPaths: [String], channelMode: AudioInputConfig.ChannelMode) async -> [Result<[Float], Swift.Error>] {
        await AudioProcessor.loadAudio(at: audioPaths, channelMode: channelMode)
    }

    static func padOrTrimAudio(fromArray audioArray: [Float], startAt startIndex: Int, toLength frameLength: Int, saveSegment: Bool) -> MLMultiArray? {
        AudioProcessor.padOrTrimAudio(fromArray: audioArray, startAt: startIndex, toLength: frameLength, saveSegment: saveSegment)
    }
}
