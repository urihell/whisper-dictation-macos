import Foundation

/// Bridges `SettingsExport` ↔ the live `AppSettings`. Export snapshots every
/// portable setting; apply assigns only the fields present in the file (each
/// assignment persists through the @Published didSet observers).
@MainActor
enum SettingsPorter {
    enum PorterError: LocalizedError {
        case unreadable
        var errorDescription: String? { "That file isn't a WhisperDictation settings export." }
    }

    static func exportData() throws -> Data {
        let s = AppSettings.shared
        var e = SettingsExport()
        e.triggerMode = s.triggerMode.rawValue
        e.doubleTapEnabled = s.doubleTapEnabled
        e.useSingleKey = s.useSingleKey
        e.singleKeyCode = s.singleKeyCode
        e.singleKeyLabel = s.singleKeyLabel
        e.submitSendsReturn = s.submitSendsReturn
        e.transcriptionEngine = s.transcriptionEngine.rawValue
        e.appleDictationModel = s.appleDictationModel
        e.modelName = s.modelName
        e.computeBackends = s.computeBackends
        e.language = s.language
        e.directTyping = s.directTyping
        e.restoreClipboard = s.restoreClipboard
        e.pressReturnAfterInsert = s.pressReturnAfterInsert
        e.cleanupEnabled = s.cleanupEnabled
        e.voiceCommandsEnabled = s.voiceCommandsEnabled
        e.autoCapitalize = s.autoCapitalize
        e.soundCuesEnabled = s.soundCuesEnabled
        e.startSound = s.startSound
        e.stopSound = s.stopSound
        e.micWarmUp = s.micWarmUp.rawValue
        e.vocabularyTerms = s.vocabularyTerms
        e.vocabularyBiasing = s.vocabularyBiasing
        e.replacements = s.replacements
        // Strip per-profile mic overrides — device UIDs are machine-specific.
        e.appProfiles = s.appProfiles.map {
            var profile = $0
            profile.inputDeviceUID = nil
            return profile
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(e)
    }

    static func apply(_ data: Data) throws {
        guard let e = try? JSONDecoder().decode(SettingsExport.self, from: data) else {
            throw PorterError.unreadable
        }
        let s = AppSettings.shared
        if let v = e.triggerMode.flatMap(TriggerMode.init(rawValue:)) { s.triggerMode = v }
        if let v = e.doubleTapEnabled { s.doubleTapEnabled = v }
        if let v = e.useSingleKey { s.useSingleKey = v }
        if let v = e.singleKeyCode { s.singleKeyCode = v }
        if let v = e.singleKeyLabel { s.singleKeyLabel = v }
        if let v = e.submitSendsReturn { s.submitSendsReturn = v }
        if let v = e.transcriptionEngine.flatMap(TranscriptionEngine.init(rawValue:)) { s.transcriptionEngine = v }
        if let v = e.appleDictationModel { s.appleDictationModel = v }
        if let v = e.modelName { s.modelName = v }
        if let v = e.computeBackends { s.computeBackends = v }
        if let v = e.language { s.language = v }
        if let v = e.directTyping { s.directTyping = v }
        if let v = e.restoreClipboard { s.restoreClipboard = v }
        if let v = e.pressReturnAfterInsert { s.pressReturnAfterInsert = v }
        if let v = e.cleanupEnabled { s.cleanupEnabled = v }
        if let v = e.voiceCommandsEnabled { s.voiceCommandsEnabled = v }
        if let v = e.autoCapitalize { s.autoCapitalize = v }
        if let v = e.soundCuesEnabled { s.soundCuesEnabled = v }
        if let v = e.startSound { s.startSound = v }
        if let v = e.stopSound { s.stopSound = v }
        if let v = e.micWarmUp.flatMap(MicWarmUp.init(rawValue:)) { s.micWarmUp = v }
        if let v = e.vocabularyTerms { s.vocabularyTerms = v }
        if let v = e.vocabularyBiasing { s.vocabularyBiasing = v }
        if let v = e.replacements { s.replacements = v }
        if let v = e.appProfiles { s.appProfiles = v }
        // NOTE: audioInputDeviceUID is untouched by design — the importing
        // Mac keeps its own microphone selection.
    }
}
