import SwiftUI

/// The content of the floating overlay shown while dictating.
struct DictationHUD: View {
    @ObservedObject var transcriber: StreamingTranscriber
    @ObservedObject var controller: DictationController

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            indicator
                .frame(width: 24, height: 24)
                .padding(.top, 1)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    Text(displayText)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(Self.textAnchor)
                }
                .frame(height: 72) // ~4 lines; longer text scrolls
                .onChange(of: displayText) {
                    // Keep the most recent words in view as dictation grows.
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(Self.textAnchor, anchor: .bottom)
                    }
                }
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
    }

    private static let textAnchor = "hud-text"

    @ViewBuilder
    private var indicator: some View {
        switch controller.state {
        case .preparing:
            ProgressView()
                .controlSize(.small)
        case .cleaning:
            Image(systemName: "sparkles")
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .foregroundStyle(Color.brand)
        case .transcribing, .inserting:
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .foregroundStyle(Color.brand)
        default:
            LevelMeter(level: CGFloat(transcriber.audioLevel))
        }
    }

    private var displayText: String {
        switch controller.state {
        case .preparing:
            return transcriber.isModelLoading ? "Loading model…" : "Starting…"
        case .cleaning:
            return "Cleaning up…"
        case .transcribing, .inserting:
            return transcriber.liveText.isEmpty ? "Finishing…" : transcriber.liveText
        default:
            return transcriber.liveText.isEmpty ? "Listening…" : transcriber.liveText
        }
    }
}

/// A compact voice-reactive level meter (replaces the static recording dot).
private struct LevelMeter: View {
    /// Smoothed mic level, 0...1.
    var level: CGFloat

    private static let weights: [CGFloat] = [0.55, 0.9, 1.0, 0.7]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(Self.weights.enumerated()), id: \.offset) { _, weight in
                Capsule()
                    .fill(Color.brand)
                    .frame(width: 3, height: height(weight))
            }
        }
        .frame(width: 24, height: 22)
        .animation(.easeOut(duration: 0.12), value: level)
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
