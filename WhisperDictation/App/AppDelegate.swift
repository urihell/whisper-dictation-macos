import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Wire the global hotkey handlers.
        HotkeyManager.shared.start()

        // Nudge the user toward granting Accessibility access (needed for ⌘V
        // injection). Non-blocking — the system shows its own prompt.
        TextInserter.ensureAccessibilityPermission(prompt: true)
    }
}
