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
    /// Insert by synthesizing the characters directly rather than pasting via the
    /// clipboard. Keeps dictated text off the pasteboard entirely, so no clipboard
    /// manager can ever capture it. On by default; turn off to fall back to
    /// clipboard paste for apps that mishandle synthesized Unicode input.
    @Published var directTyping: Bool {
        didSet { defaults.set(directTyping, forKey: Keys.directTyping) }
    }
    /// Press Return after inserting, to submit chat boxes/search fields.
    @Published var pressReturnAfterInsert: Bool {
        didSet { defaults.set(pressReturnAfterInsert, forKey: Keys.pressReturn) }
    }
    /// Run on-device LLM cleanup (remove self-corrections + filler) before insert.
    @Published var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: Keys.cleanupEnabled) }
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
    /// Double-tap the trigger to start hands-free (latched) dictation.
    @Published var doubleTapEnabled: Bool {
        didSet { defaults.set(doubleTapEnabled, forKey: Keys.doubleTapEnabled) }
    }
    /// In double-tap mode, whether submitting (single tap / Enter) also presses
    /// Return to send. When false, it only inserts.
    @Published var submitSendsReturn: Bool {
        didSet { defaults.set(submitSendsReturn, forKey: Keys.submitSendsReturn) }
    }
    /// Virtual key code of the single-key trigger, or -1 if unset.
    @Published var singleKeyCode: Int {
        didSet { defaults.set(singleKeyCode, forKey: Keys.singleKeyCode) }
    }
    /// Human-readable label for the single-key trigger.
    @Published var singleKeyLabel: String {
        didSet { defaults.set(singleKeyLabel, forKey: Keys.singleKeyLabel) }
    }

    /// Custom vocabulary — terms seeded into the recognizer's prompt so names,
    /// jargon, and acronyms are transcribed correctly.
    @Published var vocabularyTerms: [String] {
        didSet { defaults.set(vocabularyTerms, forKey: Keys.vocabularyTerms) }
    }
    /// Feed the vocabulary into the decoder prompt. Off by default: it disables
    /// WhisperKit's prefill cache, which noticeably slows live transcription.
    @Published var vocabularyBiasing: Bool {
        didSet { defaults.set(vocabularyBiasing, forKey: Keys.vocabularyBiasing) }
    }
    /// Post-transcription replacements (heard text → corrected text).
    @Published var replacements: [String: String] {
        didSet { defaults.set(replacements, forKey: Keys.replacements) }
    }

    var forcedLanguageCode: String? {
        language == "auto" ? nil : language
    }

    private init() {
        triggerMode = TriggerMode(rawValue: defaults.string(forKey: Keys.triggerMode) ?? "") ?? .toggle
        modelName = defaults.string(forKey: Keys.modelName) ?? "openai_whisper-base"
        restoreClipboard = defaults.object(forKey: Keys.restoreClipboard) as? Bool ?? true
        directTyping = defaults.object(forKey: Keys.directTyping) as? Bool ?? true
        pressReturnAfterInsert = defaults.object(forKey: Keys.pressReturn) as? Bool ?? false
        cleanupEnabled = defaults.object(forKey: Keys.cleanupEnabled) as? Bool ?? false
        language = defaults.string(forKey: Keys.language) ?? "auto"
        useSingleKey = defaults.object(forKey: Keys.useSingleKey) as? Bool ?? false
        doubleTapEnabled = defaults.object(forKey: Keys.doubleTapEnabled) as? Bool ?? true
        submitSendsReturn = defaults.object(forKey: Keys.submitSendsReturn) as? Bool ?? true
        singleKeyCode = defaults.object(forKey: Keys.singleKeyCode) as? Int ?? -1
        singleKeyLabel = defaults.string(forKey: Keys.singleKeyLabel) ?? ""
        vocabularyTerms = defaults.stringArray(forKey: Keys.vocabularyTerms) ?? []
        vocabularyBiasing = defaults.object(forKey: Keys.vocabularyBiasing) as? Bool ?? false
        replacements = (defaults.dictionary(forKey: Keys.replacements) as? [String: String]) ?? [:]
    }

    private enum Keys {
        static let triggerMode = "triggerMode"
        static let modelName = "modelName"
        static let restoreClipboard = "restoreClipboard"
        static let directTyping = "directTyping"
        static let pressReturn = "pressReturnAfterInsert"
        static let cleanupEnabled = "cleanupEnabled"
        static let language = "language"
        static let useSingleKey = "useSingleKey"
        static let doubleTapEnabled = "doubleTapEnabled"
        static let submitSendsReturn = "submitSendsReturn"
        static let singleKeyCode = "singleKeyCode"
        static let singleKeyLabel = "singleKeyLabel"
        static let vocabularyTerms = "vocabularyTerms"
        static let vocabularyBiasing = "vocabularyBiasing"
        static let replacements = "replacements"
    }
}
