import Foundation
import Combine

/// Drives the menu bar icon based on the current dictation state.
@MainActor
final class StatusController: ObservableObject {
    static let shared = StatusController()

    @Published var state: DictationState = .idle

    var symbolName: String {
        switch state {
        case .idle: return "mic"
        case .preparing: return "mic.badge.plus"
        case .recording: return "mic.fill"
        case .transcribing, .inserting: return "waveform"
        }
    }

    private init() {}
}
