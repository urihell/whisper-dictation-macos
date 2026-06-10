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

        // First-launch intro: a menu-bar app shows nothing on open, so explain
        // where it lives and how to start. Skipped once the user opts out.
        WelcomeController.shared.showIfNeeded()
    }

    // Re-launching an already-running app (Spotlight, Finder, Launchpad, the
    // Dock) fires this. For a menu-bar-only (LSUIElement) app it's the reliable
    // escape hatch when the menu bar icon is hidden off-screen (notch, too many
    // items, Bartender): opening the app again brings up Settings. ⌘, can't be
    // trusted here because the app is rarely the frontmost one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI's Settings scene is opened via this AppKit selector (macOS 14+).
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        return true
    }

    // Hard-release a warm microphone on quit so the mic-in-use indicator never
    // outlives the app (the warm-up feature keeps the mic engine flowing between
    // dictations; this is the final backstop).
    func applicationWillTerminate(_ notification: Notification) {
        DictationController.shared.releaseWarmMicNow()
    }
}
