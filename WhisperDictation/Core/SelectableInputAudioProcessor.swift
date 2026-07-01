import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
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
    /// True while the engine is kept running between sessions ("warm idle") so the
    /// next dictation adopts an already-flowing engine and avoids VPIO's ~800ms
    /// cold-start. While warm-idle there is no session callback; ingest keeps only
    /// a short rolling tail and discards the rest.
    ///
    /// Read on the audio tap thread (`ingest`) and written on the main actor
    /// (`enterWarmIdle`/`startRecordingLive`/`teardown`) without a
    /// lock — consistent with this class's existing `@unchecked Sendable` access to
    /// `inner`'s buffers. A torn read only changes whether one extra buffer is
    /// tail-capped, which is harmless; `Bool` access is atomic in practice.
    private(set) var isWarmIdle = false
    /// Rolling tail cap while warm-idle (engine flowing, no session). 16 kHz × 1s.
    private let maxIdleSamples = WhisperKit.sampleRate
    /// Serializes mutation of `inner.audioSamples` / `inner.audioEnergy` between the
    /// real-time tap thread (`ingest`) and the main actor (the buffer clears in the
    /// warm-idle adopt / enter paths). Without it, reassigning the arrays to `[]`
    /// while the tap is mid-`append` is a concurrent writer/writer race (UB on the
    /// COW storage). Held only for the O(1) reset / O(buffer) append — never across
    /// the engine or callback.
    private let bufferLock = NSLock()

    /// Reset the shared capture buffers under the lock — safe to call while the
    /// warm engine's tap is still firing.
    private func clearBuffersLocked() {
        bufferLock.lock()
        inner.audioSamples = []
        inner.audioEnergy = []
        bufferLock.unlock()
    }
    /// When true, `stopRecording()` keeps the VPIO engine running (warm idle)
    /// instead of tearing it down — so the next session adopts it instantly. Set
    /// by the controller from the "Microphone warm-up" setting. Ignored on the
    /// non-VPIO (Bluetooth) path.
    var keepWarmOnStop = false

    /// The complete session audio, snapshotted inside `stopRecording()` at the
    /// instant capture ended — BEFORE `enterWarmIdle()` clears the live buffers.
    /// The transcriber reads this after stopping the stream so its tail re-decode
    /// includes every captured sample; reading `audioSamples` after stop would
    /// find them already wiped on the warm-idle path. Cleared at session start.
    private var _samplesAtStop: ContiguousArray<Float>?
    var samplesAtStop: ContiguousArray<Float>? {
        bufferLock.lock(); defer { bufferLock.unlock() }
        return _samplesAtStop
    }

    // MARK: - Device injection / Voice-Isolation capture

    /// Open the Voice-Processing capture engine NOW — before a session exists — so
    /// Move a just-finished session's engine back into warm idle: keep it running
    /// and flowing, but detach the session callback and reset buffers so the next
    /// dictation starts instantly. No-op if there's no engine (non-VPIO path).
    func enterWarmIdle() {
        guard isolationEngine != nil else { return }
        isWarmIdle = true            // set before clearing so ingest applies the idle cap
        isolationCallback = nil
        clearBuffersLocked()
        Log.info("Voice Isolation: engine kept warm (idle).")
    }

    /// Fully release the engine and the microphone (Off mode, warm-window expiry,
    /// device change, app background/quit). Safe to call when nothing is running.
    func releaseWarmEngine() {
        guard isolationEngine != nil else { return }
        teardownIsolationEngine()
        Log.info("Voice Isolation: warm engine released.")
    }

    func startRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        let device = inputDeviceID ?? selectedDeviceID
        clearStopSnapshot()
        // Adopt a warm-idle engine: just attach the streamer's callback and keep
        // the already-converged, flowing engine. Only valid if this session also
        // wants VPIO (both warm-idle and session use the built-in/wired path).
        if isWarmIdle, isolationEngine != nil, voiceIsolationEnabled {
            isWarmIdle = false           // stop the idle cap before attaching the session
            clearBuffersLocked()         // drop idle pre-roll; safe vs the still-firing tap
            isolationCallback = callback
            Log.info("Voice Isolation: adopted warm engine (instant start).")
            return
        }
        // A warm engine exists but this session doesn't want VPIO (e.g. device
        // flipped to Bluetooth): discard it and take the plain path.
        if isWarmIdle { teardownIsolationEngine() }
        guard voiceIsolationEnabled else {
            // Pre-flight the input format to turn a corrupted-TCC 0/0 format into a
            // catchable error instead of an uncatchable installTap crash — but ONLY
            // for non-Bluetooth devices. The probe spins up a throwaway AVAudioEngine
            // and reads its input node, which on a Bluetooth headset (AirPods) forces
            // the A2DP→HFP profile switch, then discards the engine — so WhisperKit's
            // real engine then switches the route a SECOND time. That double open
            // adds ~1s of first-word loss on every Bluetooth dictation. Connected
            // Bluetooth mics always report a valid format, so the probe buys nothing
            // there; skip it and let WhisperKit open the route exactly once.
            if !Self.isResolvedDeviceBluetooth(device) {
                try Self.assertInputFormatUsable()
            }
            try inner.startRecordingLive(inputDeviceID: device, callback: callback)
            return
        }
        do {
            try startIsolatedRecording(inputDeviceID: device, callback: callback)
        } catch {
            // VPIO is an enhancement, not a requirement. Its audio unit can fail
            // to initialize (observed: kAudioUnitErr_FailedInitialization / -10875
            // right after switching the input device, while CoreAudio is still
            // reconfiguring). Don't kill the session — release the half-built
            // engine and fall back to plain capture so dictation still works.
            Log.error("Voice Isolation: engine failed to start (\(error)); falling back to plain capture.")
            teardownIsolationEngine()
            voiceIsolationEnabled = false   // reflect actual state on stop/resume
            try inner.startRecordingLive(inputDeviceID: device, callback: callback)
        }
    }

    func startStreamingRecordingLive(inputDeviceID: DeviceID?) -> (AsyncThrowingStream<[Float], Error>, AsyncThrowingStream<[Float], Error>.Continuation) {
        // Streaming-stream API isn't used by this app's transcriber (it uses the
        // callback form above), so leave it on the wrapped processor's default
        // path — Voice Isolation only needs to cover the path we actually drive.
        inner.startStreamingRecordingLive(inputDeviceID: inputDeviceID ?? selectedDeviceID)
    }

    func resumeRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        let device = inputDeviceID ?? selectedDeviceID
        clearStopSnapshot()
        guard voiceIsolationEnabled else {
            // Skip the throwaway-engine probe for Bluetooth — it double-opens the
            // route and costs ~1s of first-word loss on AirPods. See startRecordingLive.
            if !Self.isResolvedDeviceBluetooth(device) {
                try Self.assertInputFormatUsable()
            }
            try inner.resumeRecordingLive(inputDeviceID: device, callback: callback)
            return
        }
        // Our engine is fully torn down on stop, so resume just rebuilds it.
        do {
            try startIsolatedRecording(inputDeviceID: device, callback: callback)
        } catch {
            // Same VPIO-is-optional fallback as startRecordingLive (see there).
            Log.error("Voice Isolation: engine failed to resume (\(error)); falling back to plain capture.")
            teardownIsolationEngine()
            voiceIsolationEnabled = false
            try inner.resumeRecordingLive(inputDeviceID: device, callback: callback)
        }
    }

    /// Builds a Voice-Processing capture engine and pumps isolated 16 kHz mono
    /// samples into `inner`'s public buffers (mirroring its private `processBuffer`),
    /// so everything downstream — the streamer's polling of `audioSamples` /
    /// `relativeEnergy` and the per-buffer callback — works unchanged.
    private func startIsolatedRecording(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        // Match AudioProcessor.startRecordingLive: clear prior session state.
        // (No tap is running yet on this cold path, but use the locked clear for
        // consistency with the warm paths.)
        clearBuffersLocked()
        isolationCallback = callback
        try buildAndStartIsolationEngine(inputDeviceID: inputDeviceID)
    }

    /// Builds the Voice-Processing capture graph and starts the engine. Used by the
    /// immediate-start path (`startIsolatedRecording`).
    private func buildAndStartIsolationEngine(inputDeviceID: DeviceID?) throws {
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
        // Mutate the shared buffers under the lock — the main actor may clear them
        // (warm-idle adopt/enter) concurrently with this tap-thread append.
        bufferLock.lock()
        inner.audioSamples.append(contentsOf: buffer)
        let minAvgEnergy = inner.audioEnergy.suffix(20).reduce(Float.infinity) { min($0, $1.avg) }
        let relativeEnergy = AudioProcessor.calculateRelativeEnergy(of: buffer, relativeTo: minAvgEnergy)
        let signalEnergy = AudioProcessor.calculateEnergy(of: buffer)
        inner.audioEnergy.append((relativeEnergy, signalEnergy.avg, signalEnergy.max, signalEnergy.min))
        // While warm-idle (engine flowing but no session adopted it), the buffers
        // would grow without bound over minutes of idle. Keep only a short rolling
        // tail. Cap BOTH: purgeAudioSamples trims audioSamples but not audioEnergy,
        // so trim audioEnergy explicitly too.
        if isWarmIdle, inner.audioSamples.count > maxIdleSamples {
            inner.purgeAudioSamples(keepingLast: maxIdleSamples)
            let energyCap = maxIdleSamples / inner.minBufferLength + 1
            if inner.audioEnergy.count > energyCap {
                inner.audioEnergy.removeFirst(inner.audioEnergy.count - energyCap)
            }
        }
        bufferLock.unlock()
        // Only feed a live session; while warm-idle there is no callback.
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
        isWarmIdle = false
    }

    // MARK: - Straight passthrough

    // The buffer reads/mutations below take `bufferLock` so they can't observe
    // `inner`'s arrays mid-`append` from `ingest` (COW reallocation race) on the
    // VPIO path. On the forwarded (non-VPIO) path `inner`'s own tap appends
    // without this lock — an upstream WhisperKit pattern we can't reach — but
    // the lock is uncontended there, so taking it costs nothing.
    var audioSamples: ContiguousArray<Float> {
        bufferLock.lock(); defer { bufferLock.unlock() }
        return inner.audioSamples
    }
    var relativeEnergy: [Float] {
        bufferLock.lock(); defer { bufferLock.unlock() }
        return inner.relativeEnergy
    }
    var relativeEnergyWindow: Int {
        get { inner.relativeEnergyWindow }
        set { inner.relativeEnergyWindow = newValue }
    }
    func purgeAudioSamples(keepingLast keep: Int) {
        bufferLock.lock(); defer { bufferLock.unlock() }
        inner.purgeAudioSamples(keepingLast: keep)
    }
    func pauseRecording() {
        if isolationEngine != nil { isolationEngine?.pause() } else { inner.pauseRecording() }
    }
    func stopRecording() {
        // Snapshot the full session audio at the instant capture ends, before any
        // path below can clear the live buffers (enterWarmIdle wipes them).
        bufferLock.lock()
        _samplesAtStop = inner.audioSamples
        bufferLock.unlock()
        guard isolationEngine != nil else { inner.stopRecording(); return }
        // Keep the engine flowing between sessions when warm-up is enabled, so the
        // next dictation skips VPIO's ~800ms cold start. Otherwise fully release.
        if keepWarmOnStop {
            enterWarmIdle()
        } else {
            teardownIsolationEngine()
        }
    }

    private func clearStopSnapshot() {
        bufferLock.lock()
        _samplesAtStop = nil
        bufferLock.unlock()
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

    // MARK: - Plain-capture pre-flight

    /// Throw (catchable) if the default input node reports an unusable format.
    ///
    /// WhisperKit's plain `AudioProcessor.setupEngine` reads
    /// `inputNode.outputFormat(forBus: 0)` and immediately installs a tap with it.
    /// When the microphone is unavailable to this process (denied/broken TCC
    /// grant, no input device) that format is 0 Hz / 0 channels, and
    /// `installTapOnBus` raises an Obj-C `NSException`
    /// (`IsFormatSampleRateAndChannelCountValid`) that a Swift `do/catch` cannot
    /// intercept — the app hard-terminates. We can't override WhisperKit's engine
    /// setup, so we pre-flight the very same format on a throwaway engine and turn
    /// an invalid one into a normal Swift error the caller already handles
    /// (surfaced via onStreamError → a visible failure, not a crash).
    private static func assertInputFormatUsable() throws {
        let probe = AVAudioEngine()
        let format = probe.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw WhisperError.audioProcessingFailed(
                "Microphone unavailable — check Microphone access in System Settings → Privacy & Security."
            )
        }
    }

    // MARK: - Device-aware voice-processing decision

    /// Whether to engage Apple's Voice Processing I/O for the given input device.
    ///
    /// Rationale: Voice Processing is the only way to make macOS Mic Mode (Voice
    /// Isolation) apply to a wired/built-in mic, so we WANT it there. But Bluetooth
    /// headsets (AirPods especially) already run their own hardware voice isolation
    /// + AGC before the audio reaches the Mac — stacking VPIO on top means double
    /// suppression and duelling auto-gain, which measurably degrades pickup. So we
    /// skip VPIO for Bluetooth and let the headset's clean single-stage signal
    /// through untouched.
    ///
    /// `deviceID` nil (or 0) means "system default" — we resolve the live default
    /// input device and inspect that.
    static func shouldEngageVoiceProcessing(forInputDevice deviceID: DeviceID?) -> Bool {
        let resolved = (deviceID ?? 0) != 0 ? deviceID! : defaultInputDeviceID()
        guard let resolved else { return true } // unknown → safe default (built-in behavior)
        return !isBluetoothDevice(resolved)
    }

    /// A connected input device: persistent UID + display name, both copied into
    /// Swift `String`s so nothing references CoreAudio-owned CF storage after the
    /// call returns. `id` is the UID (stable across reboots / re-plugs).
    struct InputDevice: Identifiable, Equatable {
        let id: String
        let name: String
    }

    /// Enumerate connected INPUT devices ourselves rather than via WhisperKit's
    /// `AudioProcessor.getAudioDevices()`.
    ///
    /// Why: that helper returned device objects whose name backing could be freed
    /// mid-use, and calling it while the warm VPIO engine's transient aggregate
    /// device was being created/torn down crashed in `objc_retain` on a dangling
    /// object (use-after-free during Settings' device-list build). Here we read
    /// every property into an owned Swift value immediately — UID and name as
    /// `String` — and skip devices with no input streams, so the returned array
    /// holds no live CoreAudio references.
    static func connectedInputDevices() -> [InputDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &ids
        ) == noErr else { return [] }

        return ids.compactMap { id -> InputDevice? in
            guard hasInputStreams(id), let uid = deviceUID(for: id) else { return nil }
            return InputDevice(id: uid, name: deviceName(for: id) ?? uid)
        }
    }

    /// True if the device exposes at least one input stream (i.e. it's a mic, not
    /// an output-only device). Reads the input-scope stream configuration.
    private static func hasInputStreams(_ deviceID: DeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(deviceID), &addr, 0, nil, &size) == noErr
        else { return false }
        return size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    /// The device's human-readable name as an owned Swift `String`, or nil.
    private static func deviceName(for deviceID: DeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let err = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(AudioObjectID(deviceID), &addr, 0, nil, &size, ptr)
        }
        guard err == noErr, let name else { return nil }
        return name as String   // copies into a Swift String; no CF reference retained
    }

    /// The device's persistent UID (`kAudioDevicePropertyDeviceUID`), or nil.
    /// `AudioDeviceID`s are runtime handles that change across reboots and
    /// replugs — the UID is the only identity safe to persist in settings.
    static func deviceUID(for deviceID: DeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let err = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(AudioObjectID(deviceID), &addr, 0, nil, &size, ptr)
        }
        guard err == noErr, let uid else { return nil }
        return uid as String
    }

    /// Resolves a persisted device UID to the device's current runtime ID, or
    /// nil if the device isn't connected right now.
    static func deviceID(forUID uid: String) -> DeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var uidCF = uid as CFString
        let err = withUnsafeMutablePointer(to: &uidCF) { uidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr,
                UInt32(MemoryLayout<CFString>.size), uidPtr,
                &size, &deviceID
            )
        }
        guard err == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    /// The display name of a device by its runtime ID (owned Swift `String`), or nil.
    /// Public wrapper over the internal name reader for the wrong-input warning.
    static func deviceName(forID deviceID: DeviceID) -> String? {
        deviceName(for: deviceID)
    }

    /// The display name of the current system default input device, or nil.
    static func defaultInputDeviceName() -> String? {
        guard let id = defaultInputDeviceID() else { return nil }
        return deviceName(for: id)
    }

    /// The current system default input device, or nil if it can't be read.
    private static func defaultInputDeviceID() -> DeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        guard err == noErr, dev != 0 else { return nil }
        return dev
    }

    /// Whether the device a session will actually capture from is Bluetooth.
    /// `nil`/0 means "system default" — resolve and inspect the live default,
    /// mirroring `shouldEngageVoiceProcessing`. Unknown → false (treat as wired,
    /// so the safety probe still runs).
    private static func isResolvedDeviceBluetooth(_ deviceID: DeviceID?) -> Bool {
        let resolved = (deviceID ?? 0) != 0 ? deviceID! : defaultInputDeviceID()
        guard let resolved else { return false }
        return isBluetoothDevice(resolved)
    }

    /// True if the device's Core Audio transport type is Bluetooth (classic or LE).
    private static func isBluetoothDevice(_ deviceID: DeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(deviceID), &addr, 0, nil, &size, &transport)
        guard err == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}
