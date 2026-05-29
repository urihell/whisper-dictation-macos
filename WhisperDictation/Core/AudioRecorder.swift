import AVFoundation

/// Captures microphone audio via `AVAudioEngine` and resamples it to the
/// 16 kHz mono Float32 format WhisperKit expects.
final class AudioRecorder {
    enum RecorderError: LocalizedError {
        case microphoneDenied
        case engineFailure(String)

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                return "Microphone access was denied. Enable it in System Settings → Privacy & Security → Microphone."
            case .engineFailure(let detail):
                return "Audio engine failed to start: \(detail)"
            }
        }
    }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    /// Prompts for microphone permission, returning whether it was granted.
    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    func start() async throws {
        guard await requestPermission() else { throw RecorderError.microphoneDenied }

        lock.withLock { samples.removeAll() }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineFailure(error.localizedDescription)
        }
    }

    /// Stops capture and returns the accumulated 16 kHz mono samples.
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return lock.withLock {
            let result = samples
            samples.removeAll()
            return result
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        if let conversionError {
            NSLog("AudioRecorder conversion error: \(conversionError)")
            return
        }

        guard let channel = output.floatChannelData, output.frameLength > 0 else { return }
        let frames = Int(output.frameLength)
        let chunk = Array(UnsafeBufferPointer(start: channel[0], count: frames))
        lock.withLock { samples.append(contentsOf: chunk) }
    }
}
