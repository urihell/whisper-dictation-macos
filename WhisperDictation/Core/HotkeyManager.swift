import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleDictation = Self("toggleDictation")
}

/// Wires the global dictation hotkey to the controller. The handlers branch on
/// the current trigger mode at call time, so changing modes needs no rewiring.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()
    private init() {}

    func start() {
        KeyboardShortcuts.onKeyDown(for: .toggleDictation) {
            switch AppSettings.shared.triggerMode {
            case .toggle:
                DictationController.shared.toggle()
            case .pushToTalk:
                DictationController.shared.begin()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .toggleDictation) {
            if AppSettings.shared.triggerMode == .pushToTalk {
                Task { await DictationController.shared.end() }
            }
        }
    }
}
