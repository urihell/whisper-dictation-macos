import Foundation
import Combine

enum TriggerMode: String, CaseIterable, Identifiable {
    case toggle
    case pushToTalk

    var id: String { rawValue }

    var label: String {
        switch self {
        case .toggle: return "Toggle (press to start, press to stop)"
        case .pushToTalk: return "Push-to-talk (hold to speak)"
        }
    }
}

/// UserDefaults-backed preferences, observable for SwiftUI bindings.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var triggerMode: TriggerMode {
        didSet { defaults.set(triggerMode.rawValue, forKey: Keys.triggerMode) }
    }
    @Published var modelName: String {
        didSet { defaults.set(modelName, forKey: Keys.modelName) }
    }
    @Published var restoreClipboard: Bool {
        didSet { defaults.set(restoreClipboard, forKey: Keys.restoreClipboard) }
    }
    /// Press Return after inserting, to submit chat boxes/search fields.
    @Published var pressReturnAfterInsert: Bool {
        didSet { defaults.set(pressReturnAfterInsert, forKey: Keys.pressReturn) }
    }
    /// ISO language code, or "auto" for detection.
    @Published var language: String {
        didSet { defaults.set(language, forKey: Keys.language) }
    }

    /// When true, the trigger is a single key (intercepted globally) rather
    /// than a KeyboardShortcuts key combination.
    @Published var useSingleKey: Bool {
        didSet { defaults.set(useSingleKey, forKey: Keys.useSingleKey) }
    }
    /// Virtual key code of the single-key trigger, or -1 if unset.
    @Published var singleKeyCode: Int {
        didSet { defaults.set(singleKeyCode, forKey: Keys.singleKeyCode) }
    }
    /// Human-readable label for the single-key trigger.
    @Published var singleKeyLabel: String {
        didSet { defaults.set(singleKeyLabel, forKey: Keys.singleKeyLabel) }
    }

    var forcedLanguageCode: String? {
        language == "auto" ? nil : language
    }

    private init() {
        triggerMode = TriggerMode(rawValue: defaults.string(forKey: Keys.triggerMode) ?? "") ?? .toggle
        modelName = defaults.string(forKey: Keys.modelName) ?? "openai_whisper-base"
        restoreClipboard = defaults.object(forKey: Keys.restoreClipboard) as? Bool ?? true
        pressReturnAfterInsert = defaults.object(forKey: Keys.pressReturn) as? Bool ?? false
        language = defaults.string(forKey: Keys.language) ?? "auto"
        useSingleKey = defaults.object(forKey: Keys.useSingleKey) as? Bool ?? false
        singleKeyCode = defaults.object(forKey: Keys.singleKeyCode) as? Int ?? -1
        singleKeyLabel = defaults.string(forKey: Keys.singleKeyLabel) ?? ""
    }

    private enum Keys {
        static let triggerMode = "triggerMode"
        static let modelName = "modelName"
        static let restoreClipboard = "restoreClipboard"
        static let pressReturn = "pressReturnAfterInsert"
        static let language = "language"
        static let useSingleKey = "useSingleKey"
        static let singleKeyCode = "singleKeyCode"
        static let singleKeyLabel = "singleKeyLabel"
    }
}
