import Foundation
import AVFoundation
import CoreML
import WhisperKit

/// An `AudioProcessing` decorator that records from a user-chosen input device.
///
/// WhisperKit's `AudioStreamTranscriber` always starts recording with the default
/// (nil) device and exposes no way to pass one, and the real `AudioProcessor`
/// method that takes a device id isn't `open` — so we can't subclass-override it.
/// Instead we wrap a real `AudioProcessor` and, whenever a caller asks for the
/// default device (nil), substitute the user's `selectedDeviceID`. Everything else
/// forwards straight through to the wrapped instance.
final class SelectableInputAudioProcessor: AudioProcessing, @unchecked Sendable {
    /// Core Audio input device to capture from, or nil for the system default.
    var selectedDeviceID: DeviceID?

    /// The real processor doing all the work.
    let inner = AudioProcessor()

    // MARK: - Device injection (substitute the selection when the caller asks for default)

    func startRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        try inner.startRecordingLive(inputDeviceID: inputDeviceID ?? selectedDeviceID, callback: callback)
    }

    func startStreamingRecordingLive(inputDeviceID: DeviceID?) -> (AsyncThrowingStream<[Float], Error>, AsyncThrowingStream<[Float], Error>.Continuation) {
        inner.startStreamingRecordingLive(inputDeviceID: inputDeviceID ?? selectedDeviceID)
    }

    func resumeRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        try inner.resumeRecordingLive(inputDeviceID: inputDeviceID ?? selectedDeviceID, callback: callback)
    }

    // MARK: - Straight passthrough

    var audioSamples: ContiguousArray<Float> { inner.audioSamples }
    var relativeEnergy: [Float] { inner.relativeEnergy }
    var relativeEnergyWindow: Int {
        get { inner.relativeEnergyWindow }
        set { inner.relativeEnergyWindow = newValue }
    }
    func purgeAudioSamples(keepingLast keep: Int) { inner.purgeAudioSamples(keepingLast: keep) }
    func pauseRecording() { inner.pauseRecording() }
    func stopRecording() { inner.stopRecording() }
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
