import SwiftUI

// MARK: - Data table

/// DATA: every captured sample, newest first, one bounded page at a time —
/// what Slive typed beside what it should have typed.
struct DataTableCard: View {
    @ObservedObject var settings: Settings
    @ObservedObject var store: TrainingStore
    @ObservedObject var run: LabelRun
    /// Not observed here: only the row-local audio views tick at 10 Hz.
    let player: AudioPreviewPlayer
    /// Owned by the page so the ground-truth card's "to check" jump can turn it.
    @Binding var samplePage: Int
    @Environment(\.slivePreserveScroll) private var preserveScroll

    @State private var confirmClear = false
    /// Sample awaiting delete confirmation.
    @State private var pendingDeleteID: String?
    @State private var editingSampleID: String?
    @State private var shouldBeDraft = ""

    /// Keep the table bounded: the audio player's 10 Hz progress updates should
    /// never make SwiftUI reconsider hundreds of transcript/diff rows.
    static let samplesPerPage = 20

    static func pageCount(for count: Int) -> Int {
        max(1, (count + samplesPerPage - 1) / samplesPerPage)
    }

    private var samplesPerPage: Int { Self.samplesPerPage }

    private var pageCount: Int { Self.pageCount(for: store.count) }

    private var visibleSamples: [EditSample] {
        let newestFirst = Array(store.samples.reversed())
        let safePage = min(samplePage, pageCount - 1)
        let start = safePage * samplesPerPage
        guard start < newestFirst.count else { return [] }
        return Array(newestFirst[start..<min(start + samplesPerPage, newestFirst.count)])
    }

    private var visibleRangeText: String {
        guard store.count > 0 else { return "" }
        let start = samplePage * samplesPerPage + 1
        let end = min(start + samplesPerPage - 1, store.count)
        return "\(start)–\(end) of \(store.count)"
    }

    /// What a row's redo/Get would use, for help text.
    private var labelerName: String {
        settings.groundTruthRecipe == .consensus ? "Slive Custom" : settings.groundTruthModel
    }

    private func isWayOff(_ sample: EditSample) -> Bool { TrainingStore.isWayOff(sample) }

    private func effectiveTruth(_ sample: EditSample) -> String? {
        TrainingStore.effectiveTruth(sample)
    }

    /// A destructive edit mid-run would pull clips out from under it.
    private let busyHelp = "Stop labeling first"

    var body: some View {
        SettingsCard("DATA", trailing: {
            HStack(spacing: 12) {
                if !store.samples.isEmpty {
                    Button("Clear all") { confirmClear = true }
                        .buttonStyle(.plain)
                        .font(SliveTheme.font(11, .semibold))
                        .foregroundStyle(run.isRunning ? SliveTheme.textOff : SliveTheme.textDim)
                        .disabled(run.isRunning)
                        .help(run.isRunning ? busyHelp : "")
                }
            }
        }) {
            if store.samples.isEmpty {
                EmptyState(
                    icon: "waveform",
                    title: "No samples yet."
                )
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    tableHeaderRow
                    Divider().overlay(SliveTheme.hairlineStrong)
                    // Newest first, one bounded page at a time. `.id` anchors
                    // the way-off jump after it switches to the target page.
                    ForEach(visibleSamples) { sample in
                        dataRow(sample)
                            .id(sample.id)
                        Divider().overlay(SliveTheme.hairline)
                    }
                    if pageCount > 1 {
                        paginationControls
                            .padding(.top, 12)
                    }
                }
            }
        }
        .confirmationDialog("Delete \(store.count) sample\(store.count == 1 ? "" : "s")?",
                            isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) {
                guard !run.isRunning else { return }
                store.clearAll()
                TranscriptDiffCache.clear()
                samplePage = 0
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this sample?", isPresented: Binding(
            get: { pendingDeleteID != nil }, set: { if !$0 { pendingDeleteID = nil } })) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteID, !run.isRunning, !run.inFlight.contains(id) {
                    if player.currentID == id { player.stop() }
                    if editingSampleID == id { editingSampleID = nil }
                    TranscriptDiffCache.remove(id: id)
                    store.remove(id: id)
                }
                pendingDeleteID = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteID = nil }
        }
    }

    private var paginationControls: some View {
        HStack(spacing: 12) {
            Button {
                player.stop()
                preserveScroll {
                    samplePage = max(0, samplePage - 1)
                }
            } label: {
                Label("Newer", systemImage: "chevron.left")
            }
            .disabled(samplePage == 0)

            Spacer()
            Text(visibleRangeText)
                .font(SliveTheme.mono(11))
                .foregroundStyle(SliveTheme.textSecondary)
            Spacer()

            Button {
                player.stop()
                preserveScroll {
                    samplePage = min(pageCount - 1, samplePage + 1)
                }
            } label: {
                Label("Older", systemImage: "chevron.right")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(samplePage >= pageCount - 1)
        }
        .font(SliveTheme.font(11, .semibold))
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// Text columns cap at ~67 characters so the table stays readable at the
    /// wide tier instead of stretching into prairie-wide lines.
    private let textColumnCap: CGFloat = 420

    private var tableHeaderRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("AUDIO").frame(width: 40, alignment: .leading)
            Text("TYPED").frame(maxWidth: textColumnCap, alignment: .leading)
            Text("CORRECT").frame(maxWidth: textColumnCap, alignment: .leading)
            Spacer(minLength: 0)
        }
        .font(SliveTheme.font(10, .bold))
        .foregroundStyle(SliveTheme.textFaint)
        .tracking(0.8)
        .padding(.bottom, 8)
    }

    private func dataRow(_ sample: EditSample) -> some View {
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                // Audio column: play/pause toggles the shared player onto this row.
                DataAudioButton(sampleID: sample.id, url: store.cachedAudioURL(sample), player: player)
                .frame(width: 40, alignment: .leading)

                // What Slive output.
                Text(sample.transcript)
                    .font(SliveTheme.font(12))
                    .foregroundStyle(SliveTheme.textMid)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: textColumnCap, alignment: .leading)

                // What it should have been — corrected words highlighted.
                shouldBeCell(sample)
                    .font(SliveTheme.font(12))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: textColumnCap, alignment: .leading)

                Spacer(minLength: 8)

                // Drop this one sample (audio + row).
                let busy = run.isRunning || run.inFlight.contains(sample.id)
                Button {
                    pendingDeleteID = sample.id
                } label: {
                    Image(systemName: "trash")
                        .font(SliveTheme.controlFont)
                        .foregroundStyle(busy ? SliveTheme.textBusy : SliveTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .help(busy ? busyHelp : "Delete")
            }

            DataPlaybackScrubber(sampleID: sample.id, player: player)
        }
        .padding(.vertical, 9)
    }

    /// SHOULD BE cell states: inline human editor → manual correction →
    /// word-diffed model transcript → spinner → Get/Edit actions → dash.
    @ViewBuilder private func shouldBeCell(_ sample: EditSample) -> some View {
        if editingSampleID == sample.id {
            shouldBeEditor(sample)
        } else if run.inFlight.contains(sample.id) {
            ProgressView().controlSize(.small)
        } else if let truth = effectiveTruth(sample) {
            HStack(alignment: .top, spacing: 6) {
                truthTextView(truth, sample: sample)
                if !sample.finalText.isEmpty {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(SliveTheme.tagFont)
                        .foregroundStyle(SliveTheme.ok)
                        .help("Your edit")
                }
                // >50% divergence is rarely a correction — flag it for a
                // human ear (listen, then redo or leave it).
                if isWayOff(sample) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(SliveTheme.tagFont)
                        .foregroundStyle(SliveTheme.warn)
                        .help("Far from output")
                }
                // The consensus transcribers disagreed — the label is their
                // best guess; a listen (and the pencil) settles it.
                if LabelScope.needsALook(sample) {
                    Image(systemName: "ear.fill")
                        .font(SliveTheme.tagFont)
                        .foregroundStyle(SliveTheme.warn)
                        .help("\(Int(((sample.llmAgreement ?? 0) * 100).rounded()))% agreement")
                }
                if sample.finalText.isEmpty, sample.llmTranscript != nil {
                    // Redo the model label. A human edit, once present, remains
                    // authoritative and is never silently replaced.
                    Button { run.labelOne(sample) } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(SliveTheme.tagFont)
                            .foregroundStyle(SliveTheme.textFaint)
                    }
                    .buttonStyle(.plain)
                    .help("Redo")
                }
                Button { beginShouldBeEdit(sample) } label: {
                    Image(systemName: "pencil")
                        .font(SliveTheme.tagFont)
                        .foregroundStyle(SliveTheme.accent)
                }
                .buttonStyle(.plain)
                .help("Edit")
            }
        } else if store.hasAudio(sample) {
            HStack(spacing: 8) {
                Button { run.labelOne(sample) } label: {
                    Label("Label", systemImage: "wand.and.stars")
                        .font(SliveTheme.font(11, .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help(labelerName)
                Button { beginShouldBeEdit(sample) } label: {
                    Label("Edit", systemImage: "pencil")
                        .font(SliveTheme.font(11, .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(SliveTheme.accent)
            }
        } else {
            Text("—").foregroundStyle(SliveTheme.textFaint)
        }
    }

    private func beginShouldBeEdit(_ sample: EditSample) {
        shouldBeDraft = effectiveTruth(sample) ?? sample.transcript
        editingSampleID = sample.id
    }

    private func saveShouldBeEdit(_ sample: EditSample) {
        let cleaned = shouldBeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        TranscriptDiffCache.remove(id: sample.id)
        store.setManualTranscript(id: sample.id, text: cleaned)
        editingSampleID = nil
        shouldBeDraft = ""
    }

    private func shouldBeEditor(_ sample: EditSample) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            TextEditor(text: $shouldBeDraft)
                .font(SliveTheme.font(12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 72, maxHeight: 120)
                .background(
                    RoundedRectangle(cornerRadius: SliveTheme.rowRadius, style: .continuous)
                        .fill(SliveTheme.wellFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: SliveTheme.rowRadius, style: .continuous)
                                .strokeBorder(SliveTheme.accentRing, lineWidth: 1)
                        )
                )
            HStack(spacing: 8) {
                Button("Save") { saveShouldBeEdit(sample) }
                    .buttonStyle(.borderedProminent)
                    .tint(SliveTheme.accent)
                    .disabled(shouldBeDraft.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") {
                    editingSampleID = nil
                    shouldBeDraft = ""
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.mini)
        }
    }

    /// The word-diffed effective truth (whole-string fallback for over-length
    /// corrections; deletions render as an underline on the neighboring word).
    @ViewBuilder private func truthTextView(_ truth: String, sample: EditSample) -> some View {
        if let diffed = TranscriptDiffCache.styled(
            id: sample.id, output: sample.transcript, truth: truth,
            base: SliveTheme.textMid, changed: SliveTheme.warnStrong) {
            Text(diffed).textSelection(.enabled)
        } else {
            Text(truth)
                .foregroundStyle(truth == sample.transcript
                                 ? SliveTheme.textMid : SliveTheme.warnStrong)
                .textSelection(.enabled)
        }
    }
}
