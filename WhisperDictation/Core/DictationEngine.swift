import Foundation

/// The session surface DictationController drives, engine-agnostically: start
/// a live session, stop it and get the final transcript, or tear it down.
/// Everything else (Whisper model management, warm-mic, Apple asset installs)
/// stays engine-specific and is NOT part of this protocol — the controller
/// talks to those features on the concrete types it owns.
@MainActor
protocol DictationEngine: AnyObject {
    /// Fired when the live session fails mid-flight (mic open failure, decode
    /// error) so the controller can tear down visibly.
    var onStreamError: ((Error) -> Void)? { get set }
    /// Fired as the confirmed/finalized transcript grows during a session —
    /// feeds the incremental cleanup pipeline.
    var onConfirmedText: ((String) -> Void)? { get set }
    /// Whether the just-ended session captured any microphone audio (false →
    /// dead/contended device; the controller shows a "check your mic" hint).
    var lastSessionCapturedAudio: Bool { get }
    /// Whether the just-ended session was confidently classified as containing
    /// no speech (wrong-input situations). Engines without that signal return
    /// false — fail-open, never drops speech.
    var lastSessionSuppressedNonSpeech: Bool { get }
    /// Human-readable name of the input device a session captures from.
    var activeInputDeviceName: String? { get }

    func start(language: String?) async throws
    func stop() async -> String
    func forceStop()
}

extension StreamingTranscriber: DictationEngine {}
