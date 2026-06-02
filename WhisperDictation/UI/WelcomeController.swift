import AppKit
import SwiftUI

/// Owns the first-launch welcome window. Kept as a retained singleton so the
/// window isn't deallocated while on screen (this is a menu-bar app, so there's
/// no document/window controller chain to hold it otherwise).
@MainActor
final class WelcomeController: NSObject, NSWindowDelegate {
    static let shared = WelcomeController()
    private override init() { super.init() }

    private var window: NSWindow?

    /// Show the window if the user hasn't opted out. Called at launch.
    func showIfNeeded() {
        guard AppSettings.shared.showWelcomeOnLaunch else { return }
        show()
    }

    /// Always show the window (used by the "How to Use…" menu item).
    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.center()
            return
        }

        let hosting = NSHostingController(
            rootView: WelcomeView(onDone: { [weak self] in self?.close() })
        )
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.title = "Welcome to Whisper Dictation"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
