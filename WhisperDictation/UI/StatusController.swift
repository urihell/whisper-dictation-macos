import Foundation
import Combine
import AppKit
import ApplicationServices

/// Drives the menu bar icon based on the current dictation state, and tracks
/// whether the app is trusted for Accessibility (required to type into other
/// apps) so the UI can warn when it isn't.
@MainActor
final class StatusController: ObservableObject {
    static let shared = StatusController()

    @Published var state: DictationState = .idle
    /// Whether the process is trusted for Accessibility. Polled, because macOS
    /// offers no notification when the user grants/revokes it in System Settings.
    @Published private(set) var accessibilityTrusted: Bool = AXIsProcessTrusted()

    private var pollTimer: Timer?

    /// Show a warning glyph at rest when we can't type into other apps — the
    /// silent failure mode after the grant is revoked or on a fresh install.
    var showsAccessibilityWarning: Bool {
        !accessibilityTrusted && state == .idle
    }

    /// The menu-bar glyph (mic → text). Template image: monochrome and adapts to
    /// the menu bar in light/dark.
    var menuBarImage: NSImage {
        let img = NSImage(named: "MenuBarGlyph") ?? NSImage()
        img.isTemplate = true
        img.size = NSSize(width: 18, height: 18)
        return img
    }

    private init() {}

    /// Starts polling Accessibility trust so the menu bar reflects changes made
    /// in System Settings without a relaunch.
    func startMonitoring() {
        refreshAccessibility()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAccessibility() }
        }
    }

    private func refreshAccessibility() {
        let trusted = AXIsProcessTrusted()
        if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
    }
}
