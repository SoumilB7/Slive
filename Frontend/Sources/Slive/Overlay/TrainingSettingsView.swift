import AppKit
import SwiftUI

/// The "Training" top-level section. Holds the captured (audio → what Slive
/// output → what it should have been) data, browsable under a "Data" folder,
/// with a hard size cap that pauses capture when reached.
struct TrainingSettingsView: View {
    @ObservedObject var settings: Settings
    var accent: Color
    @ObservedObject private var store = TrainingStore.shared
    @ObservedObject private var player = AudioPreviewPlayer.shared

    /// Whether the Data folder is open (showing the table) vs. the folder tile.
    @State private var openData = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                savingCard
                if openData {
                    dataHeader
                    limitCard
                    tableCard
                } else {
                    folderTile
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .onDisappear { player.stop() }
    }

    // MARK: - Saving toggle

    /// Master switch for the whole saving procedure, right where the data lives.
    /// (The same setting also appears in Dictation → General.)
    private var savingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("SAVING")
            Toggle(isOn: $settings.captureEdits) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Save dictations (audio + transcript)")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                    Text("Runs strictly after the text has finished typing — saving never adds latency to the typeout.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(accent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    // MARK: - Folder tile

    private var folderTile: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("TRAINING")
            Button {
                openData = true
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Data")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.95))
                        Text("\(store.count) sample\(store.count == 1 ? "" : "s") · \(byteText(store.totalBytes))")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(card)
            }
            .buttonStyle(.plain)

            Text("Captured while “Save dictation recordings” is on (Dictation → General). Each row is one dictation: its audio plus what Slive transcribed it as. The “should be” column stays empty until corrected-text capture returns.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Data header (back)

    private var dataHeader: some View {
        HStack {
            Button {
                openData = false
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                    Text("Training").font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(accent)
            }
            .buttonStyle(.plain)
            Spacer()
            if !store.samples.isEmpty {
                Button("Clear all") { store.clearAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    // MARK: - Size cap

    private var limitCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("MAX DATA SIZE")
                Spacer()
                Text(String(format: "%.1f GB", settings.captureMaxGB))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent)
            }
            Slider(value: $settings.captureMaxGB, in: 0.1...20, step: 0.1)
                .tint(accent)

            // Usage bar.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1)).frame(height: 6)
                    Capsule()
                        .fill(store.isOverLimit ? Color.orange : accent)
                        .frame(width: max(4, geo.size.width * store.usageFraction), height: 6)
                }
                .frame(height: 6)
            }
            .frame(height: 6)

            HStack {
                Text("\(byteText(store.totalBytes)) used")
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                if store.isOverLimit {
                    Label("Capture paused — limit reached", systemImage: "pause.circle.fill")
                        .foregroundStyle(.orange)
                } else if settings.captureEdits {
                    Label("Capturing", systemImage: "record.circle")
                        .foregroundStyle(.green)
                } else {
                    Text("Capture off").foregroundStyle(.white.opacity(0.4))
                }
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    // MARK: - Table

    private var tableCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            tableHeaderRow
            Divider().overlay(.white.opacity(0.1))
            if store.samples.isEmpty {
                Text("No samples yet. Dictate into a text field, edit it, then move on.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 14)
            } else {
                // Newest first.
                ForEach(Array(store.samples.reversed())) { sample in
                    dataRow(sample)
                    Divider().overlay(.white.opacity(0.06))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    private var tableHeaderRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("AUDIO").frame(width: 44, alignment: .leading)
            Text("OUTPUT").frame(maxWidth: .infinity, alignment: .leading)
            Text("SHOULD BE").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .foregroundStyle(.white.opacity(0.4))
        .tracking(0.8)
        .padding(.bottom, 8)
    }

    private func dataRow(_ sample: EditSample) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                // Audio column: play/pause toggles the shared player onto this row.
                Group {
                    if let url = store.audioURL(sample) {
                        Button { player.toggle(id: sample.id, url: url) } label: {
                            Image(systemName: player.currentID == sample.id && player.isPlaying
                                    ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(accent)
                        }
                        .buttonStyle(.plain)
                        .help(player.currentID == sample.id && player.isPlaying ? "Pause" : "Play")
                    } else {
                        Image(systemName: "waveform.slash")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.25))
                    }
                }
                .frame(width: 44, alignment: .leading)

                // What Slive output.
                Text(sample.transcript)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // What it should have been (after editing).
                Text(sample.finalText.isEmpty ? "—" : sample.finalText)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(sample.edited ? .orange.opacity(0.95) : .white.opacity(0.75))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Scrubber, only under the row that's loaded in the player.
            if player.currentID == sample.id {
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { player.position },
                            set: { player.seek(to: $0) }
                        ),
                        in: 0...max(player.duration, 0.01)
                    )
                    .controlSize(.mini)
                    .tint(accent)
                    Text("\(AudioPreviewPlayer.timeText(player.position)) / \(AudioPreviewPlayer.timeText(player.duration))")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize()
                }
                .padding(.leading, 44)   // align under the text columns
            }
        }
        .padding(.vertical, 9)
    }

    // MARK: - Shared

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.4))
            .tracking(1.2)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.8)
            )
    }
}
