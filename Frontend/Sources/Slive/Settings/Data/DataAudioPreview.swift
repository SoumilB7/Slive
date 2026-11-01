import SwiftUI

/// Playback observation lives in these tiny row-local views. The 10 Hz ticker
/// therefore refreshes the controls, not the whole Data page and every diff.
struct DataAudioButton: View {
    let sampleID: String
    let url: URL?
    @ObservedObject var player: AudioPreviewPlayer

    var body: some View {
        if let url {
            Button { player.toggle(id: sampleID, url: url) } label: {
                Image(systemName: player.currentID == sampleID && player.isPlaying
                      ? "pause.circle.fill" : "play.circle.fill")
                    .font(SliveTheme.iconXL)
                    .foregroundStyle(SliveTheme.accent)
            }
            .buttonStyle(.plain)
            .help(player.currentID == sampleID && player.isPlaying ? "Pause" : "Play")
        } else {
            Image(systemName: "waveform.slash")
                .font(SliveTheme.iconMedium)
                .foregroundStyle(SliveTheme.textGhost)
        }
    }
}

struct DataPlaybackScrubber: View {
    let sampleID: String
    @ObservedObject var player: AudioPreviewPlayer

    var body: some View {
        if player.currentID == sampleID {
            HStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { player.position },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...max(player.duration, 0.01)
                )
                .controlSize(.mini)
                .tint(SliveTheme.accent)
                .frame(maxWidth: 220)
                Text("\(AudioPreviewPlayer.timeText(player.position)) / \(AudioPreviewPlayer.timeText(player.duration))")
                    .font(SliveTheme.mono(10))
                    .foregroundStyle(SliveTheme.textMuted)
                    .fixedSize()
            }
            .padding(.leading, 52)
            .padding(.horizontal, -8)
            .background(
                RoundedRectangle(cornerRadius: SliveTheme.rowRadius, style: .continuous)
                    .fill(SliveTheme.insetFill)
            )
        }
    }
}
