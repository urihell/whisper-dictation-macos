import Foundation
import Combine
import AppKit

enum DictationState {
    case idle
    case preparing   // loading model / starting the stream
    case recording   // streaming live transcription
    case transcribing // finalizing after stop
    case cleaning    // on-device LLM cleanup
    case inserting
}

/// Orchestrates a dictation session: show HUD → stream live → insert final
/// text at the cursor on stop. Publishes state for the menu bar and HUD.
@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()

    @Published private(set) var state: DictationState = .idle
    @Published var lastError: String?

    let transcriber = StreamingTranscriber()
    private let inserter = TextInserter()

    // Monitors for the Escape key, active only while dictating.
    private var escapeGlobalMonitor: Any?
    private var escapeLocalMonitor: Any?

    // Suppresses the "switched" toast for the very first model load at launch.
    private var announcedFirstModel = false

    private init() {
        transcriber.onModelReady = { [weak self] modelName in
            guard let self else { return }
            if self.announcedFirstModel {
                OverlayController.shared.toast("Switched to \(Self.friendlyModelName(modelName))")
            }
            self.announcedFirstModel = true
        }
    }

    /// Loads the configured model in the background so it's ready (or compiling)
    /// before the first dictation. Call once at launch.
    func preloadModel() {
        transcriber.requestModel(AppSettings.shared.modelName)
    }

    static func friendlyModelName(_ id: String) -> String {
        switch id {
        case "openai_whisper-tiny": return "Tiny"
        case "openai_whisper-base": return "Base"
        case "openai_whisper-small": return "Small"
        case "openai_whisper-medium": return "Medium"
        case "openai_whisper-large-v3-v20240930_turbo_632MB": return "Large v3 Turbo"
        case "openai_whisper-large-v3": return "Large v3"
        default: return id
        }
    }

    var isActive: Bool { state != .idle }

    // Trigger gesture handling (shared by the key-combo and single-key paths).
    private static let doubleTapWindow: TimeInterval = 0.3
    private var lastTriggerDownTime: Date?
    private var latched = false           // hands-free: release won't stop it
    private var pttStopToken = 0          // guards the deferred push-to-talk stop

    /// Toggle-mode entry point: start if idle, finish if live. Used by the menu.
    func toggle() {
        switch state {
        case .idle:
            begin()
        case .recording:
            Task { await end() }
        case .preparing, .transcribing, .cleaning, .inserting:
            break // busy — ignore
        }
    }

    /// The trigger key/shortcut was pressed. Handles single press, toggle, and
    /// double-tap-to-latch, regardless of trigger mode.
    func triggerDown() {
        let now = Date()
        let isDoubleTap = lastTriggerDownTime
            .map { now.timeIntervalSince($0) <= Self.doubleTapWindow } ?? false
        lastTriggerDownTime = now

        if isDoubleTap {
            // Hands-free: keep dictation running until an explicit stop press.
            latched = true
            pttStopToken &+= 1            // cancel any pending push-to-talk stop
            if state == .idle { begin() }
            return
        }

        switch state {
        case .idle:
            begin()
        case .recording:
            latched = false
            Task { await end() }
        case .preparing, .transcribing, .cleaning, .inserting:
            break // busy — ignore
        }
    }

    /// The trigger key/shortcut was released.
    func triggerUp() {
        guard !latched else { return }
        guard AppSettings.shared.triggerMode == .pushToTalk else { return }
        guard state == .recording || state == .preparing else { return }

        // Defer the stop briefly so a quick second tap can become a double-tap
        // (latching) instead of ending the session.
        pttStopToken &+= 1
        let token = pttStopToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.doubleTapWindow) { [weak self] in
            guard let self, self.pttStopToken == token, !self.latched else { return }
            if self.state == .recording || self.state == .preparing {
                Task { await self.end() }
            }
        }
    }

    func begin() {
        guard state == .idle else { return }
        Log.info("begin() — preparing")
        setState(.preparing)
        OverlayController.shared.show()
        startEscapeMonitors()
        Task {
            do {
                try await transcriber.start(language: AppSettings.shared.forcedLanguageCode)
                // If the user already released (push-to-talk) we may have been
                // moved out of .preparing; only advance if still preparing.
                if state == .preparing { setState(.recording) }
                Log.info("begin() — now \(String(describing: state))")
            } catch {
                OverlayController.shared.hide()
                fail(error)
            }
        }
    }

    func end() async {
        guard state == .preparing || state == .recording else { return }
        stopEscapeMonitors()

        setState(.transcribing)
        var text = await transcriber.stop()
        Log.info("end() — raw transcript: \(text.count) chars: \"\(text.prefix(80))\"")

        // Optional on-device cleanup (remove self-corrections + filler).
        if AppSettings.shared.cleanupEnabled, SpeechCleaner.isAvailable, !text.isEmpty {
            setState(.cleaning)
            text = await SpeechCleaner.clean(text, languageHint: AppSettings.shared.forcedLanguageCode)
        }

        OverlayController.shared.hide()

        guard !text.isEmpty else {
            Log.info("end() — empty transcript, nothing to insert")
            setState(.idle)
            return
        }

        setState(.inserting)
        inserter.insert(
            text,
            restoreClipboard: AppSettings.shared.restoreClipboard,
            pressReturn: AppSettings.shared.pressReturnAfterInsert
        )
        setState(.idle)
    }

    /// Aborts the current session and discards the transcript (Escape).
    func cancel() async {
        guard state == .preparing || state == .recording else { return }
        Log.info("cancel() — discarding dictation")
        stopEscapeMonitors()
        _ = await transcriber.stop()
        OverlayController.shared.hide()
        setState(.idle)
    }

    // MARK: - Escape-to-cancel

    private func startEscapeMonitors() {
        escapeGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return } // Escape
            Task { await self?.cancel() }
        }
        // Local monitor in case our own (HUD) window happens to be key.
        escapeLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { await self?.cancel() }
            return nil
        }
    }

    private func stopEscapeMonitors() {
        if let escapeGlobalMonitor {
            NSEvent.removeMonitor(escapeGlobalMonitor)
            self.escapeGlobalMonitor = nil
        }
        if let escapeLocalMonitor {
            NSEvent.removeMonitor(escapeLocalMonitor)
            self.escapeLocalMonitor = nil
        }
    }

    private func setState(_ newState: DictationState) {
        if newState == .idle { latched = false }
        state = newState
        StatusController.shared.state = newState
    }

    private func fail(_ error: Error) {
        stopEscapeMonitors()
        lastError = error.localizedDescription
        Log.error("Dictation failed: \(error.localizedDescription)")
        setState(.idle)
    }
}
