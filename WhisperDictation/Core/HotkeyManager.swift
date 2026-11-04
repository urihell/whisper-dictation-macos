import Foundation
import CoreGraphics
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleDictation = Self("toggleDictation")
}

/// Wires the dictation trigger. Two styles, selectable in Settings:
///   - Key combination → KeyboardShortcuts (modifier + key, or a function key),
///     or a modifier-only shortcut (Right ⌥ alone, ⌘⌥…) → ModifierShortcutMonitor.
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
            // Logged so a "hotkey did nothing" report shows whether the press
            // arrived at all, and whether a busy state swallowed it.
            Log.info("Hotkey down (state=\(DictationController.shared.state))")
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
            ModifierShortcutMonitor.shared.stop()
        } else if !settings.modifierShortcut.isEmpty {
            // Modifier-only shortcut replaces the combo. Unregister the combo so
            // it doesn't also fire (or keep consuming its keystroke).
            SingleKeyMonitor.shared.stop()
            KeyboardShortcuts.disable(.toggleDictation)
            let codes = Set(settings.modifierShortcut.map { UInt16(clamping: $0) })
            ModifierShortcutMonitor.shared.start(modifiers: codes)
        } else {
            SingleKeyMonitor.shared.stop()
            ModifierShortcutMonitor.shared.stop()
            KeyboardShortcuts.enable(.toggleDictation)
        }
    }

    /// Stop every trigger while the Settings recorder is capturing a new
    /// shortcut, so pressing it doesn't start dictation. `reconfigure()` resumes.
    func suspend() {
        KeyboardShortcuts.disable(.toggleDictation)
        SingleKeyMonitor.shared.stop()
        ModifierShortcutMonitor.shared.stop()
    }
}
