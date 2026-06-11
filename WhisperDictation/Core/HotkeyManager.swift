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
        // Ship a default shortcut (⌥Space) on first launch so dictation works out
        // of the box. Only set it when the user has none — never override a custom
        // one. ⌥Space is free on stock macOS and easy to reach one-handed.
        if KeyboardShortcuts.getShortcut(for: .toggleDictation) == nil {
            KeyboardShortcuts.setShortcut(.init(.space, modifiers: .option), for: .toggleDictation)
        }

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
        if settings.useSingleKey {
            // Unregister the key combo while single-key mode is active: a
            // registered hotkey consumes its keystroke system-wide even when
            // the handler ignores it, which would leave e.g. ⌥Space dead.
            KeyboardShortcuts.disable(.toggleDictation)
            if settings.singleKeyCode >= 0 {
                SingleKeyMonitor.shared.start(keyCode: CGKeyCode(settings.singleKeyCode))
            } else {
                SingleKeyMonitor.shared.stop()
            }
        } else {
            SingleKeyMonitor.shared.stop()
            KeyboardShortcuts.enable(.toggleDictation)
        }
    }
}
