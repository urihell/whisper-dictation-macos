import AppKit

/// Optional audio cues so you know dictation armed/disarmed without watching the
/// HUD. Off by default; uses built-in macOS system sounds (no bundled assets).
@MainActor
enum SoundFeedback {
    /// Played the instant dictation is triggered — confirms the key registered.
    /// Pop: soft and quick, so it doesn't intrude when you start talking.
    static func start() { play("Pop") }
    /// Played when dictation stops / submits. Glass: a gentle, pleasant chime
    /// that reads as "captured / done".
    static func stop() { play("Glass") }

    private static func play(_ name: String) {
        guard AppSettings.shared.soundCuesEnabled else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
