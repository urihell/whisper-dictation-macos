import SwiftUI
import AppKit

struct MenuContent: View {
    @EnvironmentObject private var controller: DictationController
    @ObservedObject private var status = StatusController.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if !status.accessibilityTrusted {
            Text("⚠️ Accessibility access needed — typing won't work")
            Button("Enable Accessibility Access…") { Self.openAccessibilitySettings() }
            Divider()
        }

        Text(statusText)

        Divider()

        Button(controller.isActive ? "Stop Dictation" : "Start Dictation") {
            controller.toggle()
        }

        Button("Settings…") {
            showSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("How to Use…") {
            WelcomeController.shared.show()
        }

        Divider()

        Button("Quit Whisper Dictation") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)

        Divider()

        Text("Whisper Dictation v\(Self.appVersion)")
    }

    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }

    private var statusText: String {
        switch controller.state {
        case .idle: return "Ready"
        case .preparing: return "Starting…"
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .cleaning: return "Cleaning up…"
        case .inserting: return "Inserting…"
        }
    }

    /// Opens Settings front-and-center every time. `SettingsLink` alone isn't
    /// enough in a menu-bar-only (LSUIElement) app: if the window is already
    /// open behind other apps it stays buried, and the TabView keeps whatever
    /// tab was last used. So: signal the view to reset to the first tab,
    /// activate the app, open the scene, and explicitly raise the window.
    private func showSettings() {
        NotificationCenter.default.post(name: .settingsAccessed, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        // If the window already existed in the background, openSettings() may
        // not raise it — order it front on the next runloop turn, once the
        // scene has (re)materialized its window.
        DispatchQueue.main.async {
            if let window = NSApp.windows.first(where: {
                $0.identifier?.rawValue.contains("Settings") == true
                    || $0.title.hasSuffix("Settings")
            }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Prompts for Accessibility and opens the System Settings pane so the user
    /// can enable typing into other apps.
    private static func openAccessibilitySettings() {
        TextInserter.ensureAccessibilityPermission(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
