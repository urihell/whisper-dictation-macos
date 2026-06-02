import AppKit

/// Optional audio cues so you know dictation armed/disarmed without watching the
/// HUD. Off by default; uses built-in macOS system sounds (no bundled assets).
/// The specific start/stop sounds are user-selectable in Settings.
@MainActor
enum SoundFeedback {
    /// Sentinel selection meaning "no sound for this event".
    static let none = "None"

    /// Selectable system sounds (from /System/Library/Sounds), pleasant ones
    /// first. Used to populate the Settings pickers.
    static let available = [
        "Pop", "Bottle", "Glass", "Submarine", "Purr", "Hero", "Tink",
        "Ping", "Frog", "Blow", "Sosumi", "Morse", "Funk", "Basso",
    ]

    /// Played the instant dictation is triggered — confirms the key registered.
    static func start() { playIfEnabled(AppSettings.shared.startSound) }
    /// Played when dictation stops / submits.
    static func stop() { playIfEnabled(AppSettings.shared.stopSound) }

    /// Play a named sound immediately, regardless of the enabled toggle — used by
    /// the Settings preview buttons so a sound can be auditioned before turning
    /// cues on.
    static func preview(_ name: String) {
        guard name != none else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    private static func playIfEnabled(_ name: String) {
        guard AppSettings.shared.soundCuesEnabled else { return }
        preview(name)
    }
}
