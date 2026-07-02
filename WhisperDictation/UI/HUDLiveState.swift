import Foundation
import Combine

/// The HIGH-FREQUENCY dictation state — live transcript (~8+ updates/sec),
/// smoothed mic level, and token-rate streaming cleanup text — isolated into
/// an object that ONLY the HUD observes.
///
/// Why isolated: the June 2026 AttributeGraph teardown crashes (see
/// tasks/lessons.md) coincided with high-rate `@Published` updates overlapping
/// a view-graph teardown. The HUD's panel and hosting view are deliberately
/// kept alive for the app's lifetime (OverlayController only orders the panel
/// out), so its graph never tears down — making it the one safe consumer of
/// rapid updates. The graphs that DO tear down constantly (the MenuBarExtra
/// dropdown on every close, Settings on window close) observe
/// DictationController / StreamingTranscriber, which after this split publish
/// only low-rate state (a few changes per session). This both shrinks the
/// teardown-race surface and stops Settings/menu from re-rendering 8×/sec
/// during dictation.
@MainActor
final class HUDLiveState: ObservableObject {
    static let shared = HUDLiveState()
    private init() {}

    /// Confirmed text plus the live tail, throttled by the transcriber.
    @Published var liveText: String = ""
    /// Smoothed microphone level (0...1) driving the HUD meter.
    @Published var audioLevel: Float = 0
    /// Cleaned text streaming out of the model during `.cleaning`, or nil.
    @Published var cleaningText: String?

    /// Reset for a fresh session start.
    func resetForSession() {
        liveText = ""
        audioLevel = 0
        cleaningText = nil
    }
}
