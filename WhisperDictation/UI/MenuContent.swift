import SwiftUI
import AppKit

struct MenuContent: View {
    @EnvironmentObject private var controller: DictationController

    var body: some View {
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
}
