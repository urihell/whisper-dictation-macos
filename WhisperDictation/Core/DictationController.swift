import Foundation
import Combine

enum DictationState {
    case idle
    case recording
    case transcribing
    case inserting
}

/// Orchestrates a dictation session: record → transcribe → insert, publishing
/// state for the menu bar UI.
@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()

    @Published private(set) var state: DictationState = .idle
    @Published var lastError: String?

    private let recorder = AudioRecorder()
    private let transcriber = TranscriptionService()
    private let inserter = TextInserter()

    private init() {}

    var isActive: Bool { state != .idle }

    /// Toggle-mode entry point: start if idle, finish if recording.
    func toggle() {
        switch state {
        case .idle:
            begin()
        case .recording:
            Task { await end() }
        case .transcribing, .inserting:
            break // busy — ignore
        }
    }

    func begin() {
        guard state == .idle else { return }
        Task {
            do {
                try await recorder.start()
                setState(.recording)
            } catch {
                fail(error)
            }
        }
    }

    func end() async {
        guard state == .recording else { return }

        let samples = recorder.stop()
        setState(.transcribing)

        do {
            let text = try await transcriber.transcribe(
                samples: samples,
                language: AppSettings.shared.forcedLanguageCode
            )
            guard !text.isEmpty else {
                setState(.idle)
                return
            }
            setState(.inserting)
            inserter.insert(text, restoreClipboard: AppSettings.shared.restoreClipboard)
            setState(.idle)
        } catch {
            fail(error)
        }
    }

    private func setState(_ newState: DictationState) {
        state = newState
        StatusController.shared.state = newState
    }

    private func fail(_ error: Error) {
        lastError = error.localizedDescription
        NSLog("Dictation error: \(error.localizedDescription)")
        setState(.idle)
    }
}
