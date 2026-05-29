import SwiftUI

/// The content of the floating overlay shown while dictating.
struct DictationHUD: View {
    @ObservedObject var transcriber: StreamingTranscriber
    @ObservedObject var controller: DictationController

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            indicator

            Text(displayText)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 460, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var indicator: some View {
        switch controller.state {
        case .preparing:
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
        case .transcribing, .inserting:
            return transcriber.liveText.isEmpty ? "Finishing…" : transcriber.liveText
        default:
            return transcriber.liveText.isEmpty ? "Listening…" : transcriber.liveText
        }
    }
}
