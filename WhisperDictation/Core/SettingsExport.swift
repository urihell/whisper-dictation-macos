import Foundation

/// The portable settings document ("Export Settings…" / "Import Settings…").
/// Every field is optional so a file from any app version imports cleanly —
/// unknown fields are ignored, missing ones leave the current value alone.
/// Enums travel as raw strings for the same reason.
///
/// Deliberately ABSENT: machine-specific identity. The global input-device
/// UID and per-profile microphone UIDs reference Core Audio devices that
/// don't exist on another Mac (the exporter strips profile mic overrides).
/// The KeyboardShortcuts key-combo also doesn't travel (it lives in the
/// library's own storage); the single-key trigger does.
struct SettingsExport: Codable, Equatable {
    var formatVersion: Int = 1

    var triggerMode: String?
    var doubleTapEnabled: Bool?
    var useSingleKey: Bool?
    var singleKeyCode: Int?
    var singleKeyLabel: String?
    var submitSendsReturn: Bool?

    var transcriptionEngine: String?
    var appleDictationModel: Bool?
    var modelName: String?
    var computeBackends: [String: String]?
    var language: String?

    var directTyping: Bool?
    var restoreClipboard: Bool?
    var pressReturnAfterInsert: Bool?

    var cleanupEnabled: Bool?
    var voiceCommandsEnabled: Bool?
    var autoCapitalize: Bool?

    var soundCuesEnabled: Bool?
    var startSound: String?
    var stopSound: String?
    var micWarmUp: String?

    var vocabularyTerms: [String]?
    var vocabularyBiasing: Bool?
    var replacements: [String: String]?
    var appProfiles: [AppProfile]?
}
