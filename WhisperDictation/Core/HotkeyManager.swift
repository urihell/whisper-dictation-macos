import Foundation
import CoreGraphics
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleDictation = Self("toggleDictation")
}

/// Wires the dictation trigger. Two styles, selectable in Settings:
///   - Key combination → KeyboardShortcuts (modifier + key, or a function key).
///   - Single key       → SingleKeyMonitor (one key, intercepted globally).
/// Handlers branch on the current trigger mode at call time, so changing
/// toggle/push-to-talk needs no rewiring.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()
    private init() {}

    func start() {
        KeyboardShortcuts.onKeyDown(for: .toggleDictation) {
            guard !AppSettings.shared.useSingleKey else { return }
            DictationController.shared.triggerDown()
        }

        KeyboardShortcuts.onKeyUp(for: .toggleDictation) {
            guard !AppSettings.shared.useSingleKey else { return }
            DictationController.shared.triggerUp()
        }

        reconfigure()
    }

    /// Call after the trigger style or single key changes.
    func reconfigure() {
        let settings = AppSettings.shared
        if settings.useSingleKey, settings.singleKeyCode >= 0 {
            SingleKeyMonitor.shared.start(keyCode: CGKeyCode(settings.singleKeyCode))
        } else {
            SingleKeyMonitor.shared.stop()
        }
    }
}
