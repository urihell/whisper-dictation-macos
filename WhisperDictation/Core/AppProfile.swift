import Foundation

/// Per-app overrides for insertion behavior, keyed by the frontmost app's
/// bundle id at insert time. Every field is tri-state: nil follows the global
/// setting, so an empty profile changes nothing. Use cases: always press
/// Return in Slack/terminals; force clipboard paste for the odd Electron app
/// that drops synthesized typing.
struct AppProfile: Codable, Identifiable, Equatable {
    var bundleID: String
    /// Display name captured when the app was added (bundle ids are opaque).
    var name: String
    /// Press Return after inserting: nil = global setting.
    var pressReturn: Bool?
    /// Insertion method: nil = global; false = direct typing; true = clipboard.
    var useClipboard: Bool?
    /// Dictation language for sessions started in this app: nil = global
    /// setting; "auto" = auto-detect; else an ISO code ("en", "he", …).
    /// Resolved at session START (unlike the insertion fields) because the
    /// language decides which engine runs. Optional in JSON, so profiles
    /// saved before this field existed decode with nil (= global).
    var language: String?
    /// Input device for sessions started in this app: nil = global setting;
    /// "" = system default; else a Core Audio device UID. Resolved at session
    /// start, like language.
    var inputDeviceUID: String?

    var id: String { bundleID }

    /// The profile matching `bundleID`, if any. Case-insensitive: bundle ids
    /// are conventionally lowercase reverse-DNS but not guaranteed.
    static func profile(for bundleID: String?, in profiles: [AppProfile]) -> AppProfile? {
        guard let bundleID else { return nil }
        return profiles.first { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }
    }
}
