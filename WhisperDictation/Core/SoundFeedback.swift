import AppKit

/// Optional audio cues so you know dictation armed/disarmed without watching the
/// HUD. Off by default; uses built-in macOS system sounds (no bundled assets).
@MainActor
enum SoundFeedback {
    /// Played the instant dictation is triggered — confirms the key registered.
    static func start() { play("Tink") }
    /// Played when dictation stops / submits.
    static func stop() { play("Pop") }

    private static func play(_ name: String) {
        guard AppSettings.shared.soundCuesEnabled else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
