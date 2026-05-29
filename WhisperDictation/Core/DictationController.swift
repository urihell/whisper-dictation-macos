import Foundation
import Combine

enum DictationState {
    case idle
    case preparing   // loading model / starting the stream
    case recording   // streaming live transcription
    case transcribing // finalizing after stop
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

    private init() {}

    var isActive: Bool { state != .idle }

    /// Toggle-mode entry point: start if idle, finish if live.
    func toggle() {
        switch state {
        case .idle:
            begin()
        case .recording:
            Task { await end() }
        case .preparing, .transcribing, .inserting:
            break // busy — ignore
        }
    }

    func begin() {
        guard state == .idle else { return }
        Log.info("begin() — preparing")
        setState(.preparing)
        OverlayController.shared.show()
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

        setState(.transcribing)
        let text = await transcriber.stop()
        OverlayController.shared.hide()

        guard !text.isEmpty else {
            setState(.idle)
            return
        }

        setState(.inserting)
        inserter.insert(text, restoreClipboard: AppSettings.shared.restoreClipboard)
        setState(.idle)
    }

    private func setState(_ newState: DictationState) {
        state = newState
        StatusController.shared.state = newState
    }

    private func fail(_ error: Error) {
        lastError = error.localizedDescription
        Log.error("Dictation failed: \(error.localizedDescription)")
        setState(.idle)
    }
}
