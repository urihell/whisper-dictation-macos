import Foundation
import Combine
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

    var symbolName: String {
        // Surface a warning at rest when we can't type into other apps — this is
        // the silent failure mode after the grant is revoked or a fresh install.
        if !accessibilityTrusted, state == .idle { return "exclamationmark.triangle.fill" }
        switch state {
        case .idle: return "mic"
        case .preparing: return "mic.badge.plus"
        case .recording: return "mic.fill"
        case .transcribing, .inserting: return "waveform"
        case .cleaning: return "sparkles"
        }
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
