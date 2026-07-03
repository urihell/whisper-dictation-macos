import AppIntents

/// Shortcuts / Siri / automation surface. Each intent is a thin adapter over
/// DictationController — the same guarded entry points the hotkeys use, so an
/// intent firing at the wrong moment is a safe no-op, never a double-start.
/// The system launches the app in the background if it isn't running; nothing
/// needs to come to the foreground (`openAppWhenRun: false`), matching the
/// menu-bar-only design.

struct ToggleDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Dictation"
    static let description = IntentDescription(
        "Starts dictation, or stops it and types the transcript at the cursor."
    )
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        DictationController.shared.toggle()
        return .result()
    }
}

struct StartDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Dictation"
    static let description = IntentDescription(
        "Begins listening. No-op if a dictation is already running."
    )
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        DictationController.shared.begin()   // guards on .idle internally
        return .result()
    }
}

struct StopDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Dictation"
    static let description = IntentDescription(
        "Stops listening and types the transcript at the cursor. Waits until insertion finishes, so following Shortcuts actions run after the text has landed."
    )
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await DictationController.shared.end()   // guards on an active session
        return .result()
    }
}

struct DictateTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Dictate Text"
    static let description = IntentDescription(
        "Starts dictation and returns the transcript to the Shortcut instead of typing it — for pipelines like dictate → translate → paste. Stop with your usual trigger (or Escape to cancel, which returns empty text). Note: very long dictations can hit Shortcuts' own action timeout."
    )
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let text = await DictationController.shared.dictateAndReturn()
        return .result(value: text)
    }
}

struct GetLastTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Last Transcript"
    static let description = IntentDescription(
        "Returns the most recent dictation transcript. The transcript is held in memory only and leaves the app solely through explicit calls like this one."
    )
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: DictationController.shared.lastTranscript ?? "")
    }
}

/// Surfaces "Toggle Dictation" in Spotlight/Siri with zero setup.
struct WhisperDictationShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleDictationIntent(),
            phrases: [
                "Toggle dictation in \(.applicationName)",
                "Start dictating with \(.applicationName)",
            ],
            shortTitle: "Toggle Dictation",
            systemImageName: "mic"
        )
    }
}
