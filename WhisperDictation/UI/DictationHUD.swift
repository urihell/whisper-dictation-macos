import SwiftUI

/// The content of the floating overlay shown while dictating.
struct DictationHUD: View {
    @ObservedObject var transcriber: StreamingTranscriber
    @ObservedObject var controller: DictationController

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            indicator
                .padding(.top, 2)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    Text(displayText)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
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
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private static let textAnchor = "hud-text"

    @ViewBuilder
    private var indicator: some View {
        switch controller.state {
        case .preparing, .cleaning:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        case .transcribing, .inserting:
            Image(systemName: "waveform")
                .foregroundStyle(.white)
        default:
            Circle()
                .fill(.red)
                .frame(width: 12, height: 12)
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
