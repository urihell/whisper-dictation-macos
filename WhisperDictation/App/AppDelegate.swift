import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Wire the global hotkey handlers.
        HotkeyManager.shared.start()

        // Nudge the user toward granting Accessibility access (needed for ⌘V
        // injection). Non-blocking — the system shows its own prompt.
        TextInserter.ensureAccessibilityPermission(prompt: true)

        // Track Accessibility trust so the menu bar can warn when typing is
        // blocked (and clear the warning once the user grants it).
        StatusController.shared.startMonitoring()

        // Start loading the configured model in the background so the first
        // dictation isn't blocked on download/compile.
        DictationController.shared.preloadModel()
    }
}
