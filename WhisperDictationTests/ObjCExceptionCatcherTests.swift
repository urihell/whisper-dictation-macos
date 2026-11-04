import XCTest
import AVFoundation

/// The 1.12–1.13 crash: AVFAudio raises an NSException (uncatchable from Swift)
/// when a tap is installed with a 0 Hz / 0 ch format — what the input node
/// reports if the default mic vanishes mid-setup. The catcher must turn that
/// into an ordinary error instead of aborting the process.
final class ObjCExceptionCatcherTests: XCTestCase {
    func testInvalidTapFormatIsCaughtNotFatal() {
        let engine = AVAudioEngine()
        let mixer = engine.mainMixerNode
        // 0 Hz / 0 ch — the exact format that killed the app.
        var asbd = AudioStreamBasicDescription()
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved
        asbd.mBitsPerChannel = 32
        guard let bad = AVAudioFormat(streamDescription: &asbd) else {
            return XCTFail("couldn't build a 0 Hz format")
        }

        XCTAssertThrowsError(try ObjCExceptionCatcher.catchException {
            mixer.installTap(onBus: 0, bufferSize: 1024, format: bad) { _, _ in }
        }) { error in
            XCTAssertEqual((error as NSError).domain, "com.apple.coreaudio.avfaudio")
        }
    }

    func testNormalBlockRunsAndSucceeds() throws {
        var ran = false
        try ObjCExceptionCatcher.catchException { ran = true }
        XCTAssertTrue(ran)
    }
}
