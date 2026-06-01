import SwiftUI
import AppKit

@main
struct WhisperDictationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = DictationController.shared
    @StateObject private var status = StatusController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(controller)
        } label: {
            Image(systemName: status.symbolName)
                .symbolEffect(
                    .pulse,
                    isActive: status.state == .recording
                        && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                )
        }

        Settings {
            SettingsView()
        }
    }
}
