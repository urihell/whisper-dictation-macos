import SwiftUI

/// The content of the floating overlay shown while dictating.
struct DictationHUD: View {
    @ObservedObject var transcriber: StreamingTranscriber
    @ObservedObject var controller: DictationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var caretOpacity: Double = 1

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            indicator
                .frame(width: 24, height: 24)
                .padding(.top, 1)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    Text(hudText)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(Self.textAnchor)
                        .onAppear {
                            guard !reduceMotion else { return }
                            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                                caretOpacity = 0.4   // never fades to near-invisible
                            }
                        }
                }
                .frame(height: 72) // ~4 lines; longer text scrolls
                .onChange(of: displayText) {
                    // Pin to the bottom as dictation grows. Instant (no animation):
                    // an animated scroll re-firing on every ~8/sec update stacked
                    // into a continuous vertical shimmer once text filled the box.
                    proxy.scrollTo(Self.textAnchor, anchor: .bottom)
                }
            }

            if transcriber.voiceIsolationActive {
                isolationBadge
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 520)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        // Transparent margin so the card's own shadow isn't clipped by the
        // (shadowless, clear) window edge — see OverlayController.makePanel.
        .padding(24)
    }

    private static let textAnchor = "hud-text"

    /// Passive indicator that this session is capturing with noise reduction on.
    /// Read-only — the HUD is a non-activating panel that must never take focus or
    /// clicks, so this only reports state; the toggle lives in the menu/Settings.
    private var isolationBadge: some View {
        Image(systemName: "waveform.badge.mic")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.brand)
            .padding(.top, 2)
            .help("Voice Isolation on for this mic")
            .accessibilityLabel("Voice Isolation on for this mic")
    }

    @ViewBuilder
    private var indicator: some View {
        switch controller.state {
        case .preparing:
            ProgressView()
                .controlSize(.small)
        case .cleaning:
            Image(systemName: "sparkles")
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                .foregroundStyle(Color.brand)
        case .transcribing, .inserting:
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                .foregroundStyle(Color.brand)
        default:
            LevelMeter(level: CGFloat(transcriber.audioLevel), reduceMotion: reduceMotion)
        }
    }

    /// A blinking caret follows the live transcript while recording — signals
    /// "still listening / more coming" and that this text will be typed.
    private var showsCaret: Bool {
        controller.state == .recording && !transcriber.liveText.isEmpty
    }

    /// The HUD text, with a brand-tinted caret appended while recording.
    private var hudText: AttributedString {
        var text = AttributedString(displayText)
        if showsCaret {
            var caret = AttributedString("▍")   // chunky bar — reads as a cursor
            // .primary matches the text: brightest in both themes (white on dark,
            // black on light) and adapts automatically — unlike a fixed color.
            caret.foregroundColor = .primary.opacity(reduceMotion ? 1 : caretOpacity)
            text += caret
        }
        return text
    }

    private var displayText: String {
        switch controller.state {
        case .preparing:
            if let p = transcriber.loadProgress {
                return "Downloading model… \(Int((p * 100).rounded()))%"
            }
            return transcriber.isModelLoading ? "Optimizing model… (first run)" : "Starting…"
        case .cleaning:
            // Streamed cleaned text as the model generates it; placeholder
            // only until the first tokens land.
            if let partial = controller.cleaningText, !partial.isEmpty {
                return partial
            }
            return "Cleaning up…"
        case .transcribing, .inserting:
            return transcriber.liveText.isEmpty ? "Finishing…" : transcriber.liveText
        default:
            return transcriber.liveText.isEmpty ? "Listening…" : transcriber.liveText
        }
    }
}

/// A compact voice-reactive level meter (replaces the static recording dot).
/// When the mic is quiet it gently "breathes" so it reads as alive/listening.
private struct LevelMeter: View {
    /// Smoothed mic level, 0...1.
    var level: CGFloat
    var reduceMotion: Bool

    @State private var breathe = false

    private static let weights: [CGFloat] = [0.55, 0.9, 1.0, 0.7]
    private var idle: Bool { level < 0.06 }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(Self.weights.enumerated()), id: \.offset) { _, weight in
                Capsule()
                    .fill(Color.brand)
                    .frame(width: 3, height: height(weight))
            }
        }
        .frame(width: 24, height: 22)
        .opacity(idle && !reduceMotion && breathe ? 0.5 : 1.0)
        .animation(.easeOut(duration: 0.12), value: level)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }

    private func height(_ weight: CGFloat) -> CGFloat {
        let minH: CGFloat = 4, maxH: CGFloat = 20
        let l = min(1, max(0, level)) * weight
        return minH + (maxH - minH) * l
    }
}

extension Color {
    /// App accent — the indigo/violet from the app icon.
    static let brand = Color(red: 0.42, green: 0.33, blue: 0.92)
}
