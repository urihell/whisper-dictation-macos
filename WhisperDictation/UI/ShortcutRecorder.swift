import SwiftUI
import AppKit
import KeyboardShortcuts

/// Records the dictation shortcut. Accepts either:
///   - a key combination (⌥/, ⌃⌘D, F5…) → stored in KeyboardShortcuts, or
///   - modifiers alone (Right ⌥, ⌘⌥ together…) → `AppSettings.modifierShortcut`,
///     captured when they're pressed and released with no other key.
/// Escape cancels. All triggers are suspended while recording so pressing the
/// current shortcut doesn't start dictation.
struct ShortcutRecorder: View {
    @ObservedObject var settings: AppSettings
    @State private var isRecording = false
    @State private var monitor: Any?
    /// Every modifier held during the current gesture.
    @State private var seenModifiers: Set<UInt16> = []

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { isRecording ? stopRecording() : startRecording() }) {
                Text(buttonTitle).frame(minWidth: 140)
            }

            if !settings.modifierShortcut.isEmpty && !isRecording {
                Button {
                    settings.modifierShortcut = []
                    HotkeyManager.shared.reconfigure()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Clear — go back to the key combination")
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private var buttonTitle: String {
        if isRecording { return "Press shortcut…" }
        if !settings.modifierShortcut.isEmpty {
            return ModifierKey.label(for: Set(settings.modifierShortcut.map { UInt16(clamping: $0) }))
        }
        return KeyboardShortcuts.getShortcut(for: .toggleDictation)?.description ?? "Record shortcut"
    }

    private func startRecording() {
        isRecording = true
        seenModifiers = []
        HotkeyManager.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            event.type == .flagsChanged ? handleFlags(event) : handleKey(event)
        }
    }

    private func handleFlags(_ event: NSEvent) -> NSEvent? {
        let held = ModifierKey.held(flags: UInt64(event.modifierFlags.rawValue))
        seenModifiers.formUnion(held)
        if held.isEmpty, !seenModifiers.isEmpty {
            // Released with no other key in between → modifier-only shortcut.
            settings.modifierShortcut = seenModifiers.map(Int.init).sorted()
            stopRecording()
        }
        return event
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53, mods.isEmpty { // Escape cancels
            stopRecording()
            return nil
        }
        // A key combo needs ⌘/⌥/⌃ — or a function key, which works alone.
        let isFunctionKey = Self.functionKeys.contains(event.keyCode)
        guard !mods.intersection([.command, .option, .control]).isEmpty || isFunctionKey,
              let shortcut = KeyboardShortcuts.Shortcut(event: event) else {
            seenModifiers = []   // a key was pressed → not a modifier-only gesture
            NSSound.beep()
            return nil
        }
        KeyboardShortcuts.setShortcut(shortcut, for: .toggleDictation)
        settings.modifierShortcut = []
        stopRecording()
        return nil
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        seenModifiers = []
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        HotkeyManager.shared.reconfigure()
    }

    private static let functionKeys: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, // F1–F12
        105, 107, 113, 106, 64, 79, 80, 90,                     // F13–F20
    ]
}
