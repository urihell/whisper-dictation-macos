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

/// Which compute units WhisperKit loads the model onto.
/// - `gpu`: Metal/GPU. Starts in seconds — the recommended default.
/// - `neuralEngine`: more power-efficient and can be faster for large models.
///   The first time a model loads on it, macOS does a one-time optimization
///   (the "optimizing" wait); the result is cached and reused on later launches.
enum ComputeBackend: String, CaseIterable, Identifiable {
    case gpu
    case neuralEngine

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gpu: return "GPU — fast startup (recommended)"
        case .neuralEngine: return "Neural Engine — efficient, one-time optimize"
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
    /// Per-model compute backend (model name → backend raw value). Each model
    /// defaults to GPU for fast, well-cached startup; the user can opt an
    /// individual model into the Neural Engine. Stored as raw strings so it
    /// round-trips cleanly through UserDefaults.
    @Published var computeBackends: [String: String] {
        didSet { defaults.set(computeBackends, forKey: Keys.computeBackends) }
    }

    /// The compute backend chosen for `model` (GPU if the user hasn't set one).
    func computeBackend(for model: String) -> ComputeBackend {
        ComputeBackend(rawValue: computeBackends[model] ?? "") ?? .gpu
    }

    /// Sets the compute backend for a single model.
    func setComputeBackend(_ backend: ComputeBackend, for model: String) {
        computeBackends[model] = backend.rawValue
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
    /// Convert spoken commands like "new line" / "new paragraph" into formatting.
    @Published var voiceCommandsEnabled: Bool {
        didSet { defaults.set(voiceCommandsEnabled, forKey: Keys.voiceCommands) }
    }
    /// Capitalize sentence starts (and standalone "i") in the final transcript.
    /// A cheap, always-fast formatting pass — no LLM. On by default.
    @Published var autoCapitalize: Bool {
        didSet { defaults.set(autoCapitalize, forKey: Keys.autoCapitalize) }
    }
    /// Play a subtle sound when dictation starts and stops. Off by default.
    @Published var soundCuesEnabled: Bool {
        didSet { defaults.set(soundCuesEnabled, forKey: Keys.soundCues) }
    }
    /// System sound name played when dictation starts ("None" = silent).
    @Published var startSound: String {
        didSet { defaults.set(startSound, forKey: Keys.startSound) }
    }
    /// System sound name played when dictation stops ("None" = silent).
    @Published var stopSound: String {
        didSet { defaults.set(stopSound, forKey: Keys.stopSound) }
    }
    /// ISO language code, or "auto" for detection.
    @Published var language: String {
        didSet { defaults.set(language, forKey: Keys.language) }
    }
    /// Core Audio input device id to capture from. 0 = follow the system default
    /// input device. Stored as Int in UserDefaults.
    @Published var audioInputDeviceID: UInt32 {
        didSet { defaults.set(Int(audioInputDeviceID), forKey: Keys.audioInputDeviceID) }
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
    /// Show the welcome / how-to-launch window on app launch. On by default so
    /// first-time users (this is a menu-bar app with no Dock icon or window)
    /// learn where it lives and how to start dictating; they can disable it.
    @Published var showWelcomeOnLaunch: Bool {
        didSet { defaults.set(showWelcomeOnLaunch, forKey: Keys.showWelcomeOnLaunch) }
    }

    var forcedLanguageCode: String? {
        language == "auto" ? nil : language
    }

    private init() {
        triggerMode = TriggerMode(rawValue: defaults.string(forKey: Keys.triggerMode) ?? "") ?? .toggle
        modelName = defaults.string(forKey: Keys.modelName) ?? "openai_whisper-base"
        computeBackends = (defaults.dictionary(forKey: Keys.computeBackends) as? [String: String]) ?? [:]
        restoreClipboard = defaults.object(forKey: Keys.restoreClipboard) as? Bool ?? true
        directTyping = defaults.object(forKey: Keys.directTyping) as? Bool ?? true
        pressReturnAfterInsert = defaults.object(forKey: Keys.pressReturn) as? Bool ?? false
        cleanupEnabled = defaults.object(forKey: Keys.cleanupEnabled) as? Bool ?? false
        voiceCommandsEnabled = defaults.object(forKey: Keys.voiceCommands) as? Bool ?? true
        autoCapitalize = defaults.object(forKey: Keys.autoCapitalize) as? Bool ?? true
        soundCuesEnabled = defaults.object(forKey: Keys.soundCues) as? Bool ?? false
        startSound = defaults.string(forKey: Keys.startSound) ?? "Pop"
        stopSound = defaults.string(forKey: Keys.stopSound) ?? "Bottle"
        language = defaults.string(forKey: Keys.language) ?? "auto"
        audioInputDeviceID = UInt32(max(0, defaults.integer(forKey: Keys.audioInputDeviceID)))
        useSingleKey = defaults.object(forKey: Keys.useSingleKey) as? Bool ?? false
        doubleTapEnabled = defaults.object(forKey: Keys.doubleTapEnabled) as? Bool ?? false
        submitSendsReturn = defaults.object(forKey: Keys.submitSendsReturn) as? Bool ?? true
        singleKeyCode = defaults.object(forKey: Keys.singleKeyCode) as? Int ?? -1
        singleKeyLabel = defaults.string(forKey: Keys.singleKeyLabel) ?? ""
        vocabularyTerms = defaults.stringArray(forKey: Keys.vocabularyTerms) ?? []
        vocabularyBiasing = defaults.object(forKey: Keys.vocabularyBiasing) as? Bool ?? false
        replacements = (defaults.dictionary(forKey: Keys.replacements) as? [String: String]) ?? [:]
        showWelcomeOnLaunch = defaults.object(forKey: Keys.showWelcomeOnLaunch) as? Bool ?? true
    }

    private enum Keys {
        static let triggerMode = "triggerMode"
        static let modelName = "modelName"
        static let computeBackends = "computeBackends"
        static let restoreClipboard = "restoreClipboard"
        static let directTyping = "directTyping"
        static let pressReturn = "pressReturnAfterInsert"
        static let cleanupEnabled = "cleanupEnabled"
        static let voiceCommands = "voiceCommandsEnabled"
        static let autoCapitalize = "autoCapitalize"
        static let soundCues = "soundCuesEnabled"
        static let startSound = "startSound"
        static let stopSound = "stopSound"
        static let language = "language"
        static let audioInputDeviceID = "audioInputDeviceID"
        static let useSingleKey = "useSingleKey"
        static let doubleTapEnabled = "doubleTapEnabled"
        static let submitSendsReturn = "submitSendsReturn"
        static let singleKeyCode = "singleKeyCode"
        static let singleKeyLabel = "singleKeyLabel"
        static let vocabularyTerms = "vocabularyTerms"
        static let vocabularyBiasing = "vocabularyBiasing"
        static let replacements = "replacements"
        static let showWelcomeOnLaunch = "showWelcomeOnLaunch"
    }
}
