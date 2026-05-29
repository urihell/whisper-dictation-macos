import SwiftUI
import AppKit

/// A minimal recorder for a single-key trigger. Click to record, then press any
/// key; Escape cancels. Stores the captured key code + label in settings.
struct SingleKeyRecorder: View {
    @ObservedObject var settings: AppSettings
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggleRecording) {
                Text(buttonTitle)
                    .frame(minWidth: 120)
            }

            if settings.singleKeyCode >= 0 && !isRecording {
                Button {
                    settings.singleKeyCode = -1
                    settings.singleKeyLabel = ""
                    HotkeyManager.shared.reconfigure()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Clear")
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private var buttonTitle: String {
        if isRecording { return "Press any key…" }
        if settings.singleKeyCode >= 0 { return settings.singleKeyLabel }
        return "Record key"
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape cancels
                stopRecording()
                return nil
            }
            settings.singleKeyCode = Int(event.keyCode)
            settings.singleKeyLabel = Self.label(for: event)
            stopRecording()
            HotkeyManager.shared.reconfigure()
            return nil // consume so it isn't typed into the field
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// Human-readable name for a key event.
    static func label(for event: NSEvent) -> String {
        if let name = specialNames[Int(event.keyCode)] { return name }
        if let chars = event.charactersIgnoringModifiers,
           let first = chars.first,
           !first.isWhitespace,
           first.isLetter || first.isNumber || first.isPunctuation || first.isSymbol {
            return chars.uppercased()
        }
        return "Key \(event.keyCode)"
    }

    private static let specialNames: [Int: String] = [
        49: "Space", 36: "Return", 76: "Enter", 48: "Tab", 51: "Delete",
        117: "Forward Delete", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}
