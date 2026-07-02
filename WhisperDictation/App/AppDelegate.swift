import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Wire the global hotkey handlers.
        HotkeyManager.shared.start()

        // Request microphone access up front. The app records via WhisperKit's
        // AVAudioEngine, which does NOT itself trigger the TCC prompt — without an
        // explicit request the grant can land in a broken state where the input
        // node reports a null (0 Hz / 0 ch) format, which then crashes AVFAudio's
        // installTapOnBus. Requesting here makes the prompt fire once and keeps the
        // grant well-defined. Non-blocking; the result only affects whether the
        // first dictation can capture (the format guard handles a hard "no").
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Log.info("Microphone access \(granted ? "granted" : "denied") by user.")
            }
        case .denied, .restricted:
            Log.error("Microphone access is denied — dictation can't capture until it's enabled in System Settings → Privacy & Security → Microphone.")
        case .authorized:
            break
        @unknown default:
            break
        }

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

        // Watch for recurrence of the June 2026 AttributeGraph teardown crash
        // (tasks/lessons.md): it was left as "monitor" — this automates the
        // monitoring by flagging any crash report written since the last launch.
        checkForNewCrashReports()
    }

    /// Logs (never uploads) any WhisperDictation crash reports newer than the
    /// previous launch, so a recurrence of the rare teardown crash is noticed
    /// instead of silently piling up in DiagnosticReports.
    private func checkForNewCrashReports() {
        let key = "lastCrashReportScan"
        let defaults = UserDefaults.standard
        let since = defaults.object(forKey: key) as? Date ?? Date()
        defaults.set(Date(), forKey: key)
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let fresh = items.filter { url in
            url.lastPathComponent.hasPrefix("WhisperDictation")
                && ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast) > since
        }
        if !fresh.isEmpty {
            Log.error("⚠️ \(fresh.count) new crash report(s) since last launch — check ~/Library/Logs/DiagnosticReports (AttributeGraph watch, lessons.md 2026-06-11).")
        }
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
