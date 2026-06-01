import SwiftUI
import AppKit

struct MenuContent: View {
    @EnvironmentObject private var controller: DictationController
    @ObservedObject private var status = StatusController.shared

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

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",", modifiers: .command)

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

    /// Prompts for Accessibility and opens the System Settings pane so the user
    /// can enable typing into other apps.
    private static func openAccessibilitySettings() {
        TextInserter.ensureAccessibilityPermission(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
