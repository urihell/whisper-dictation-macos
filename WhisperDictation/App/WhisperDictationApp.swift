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
            if status.showsAccessibilityWarning {
                Image(systemName: "exclamationmark.triangle.fill")
            } else {
                Image(nsImage: status.menuBarImage)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
