import AppKit
import SwiftUI

extension SettingsPageID {
    static let history = SettingsPageID("history")
}

extension SettingsPageSpec {
    static let history = SettingsPageSpec(
        id: .history, title: "History", icon: "clock.fill", section: .library,
        width: .list,
        status: { env in
            let entries = env.history.entries
            return SettingsPageStatus(text: entries.isEmpty ? nil : "\(entries.count) · last 24 h")
        }
    ) { ctx in
        AnyView(HistoryPage(history: ctx.env.history, stats: ctx.env.stats))
    }
}

/// Dictation · History: the speaking pace above the last 24 h of transcripts.
struct HistoryPage: View {
    @ObservedObject var history: HistoryStore
    @ObservedObject var stats: SpeakingStats

    @State private var confirmClearHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            paceLine
            historyCard
        }
    }

    // MARK: Speaking pace (words per minute)

    /// One line above History: last take's pace, then avg / best / takes.
    /// Measured after each dictation's text is written, so it never adds
    /// latency to what you type.
    @ViewBuilder private var paceLine: some View {
        if stats.sampleCount > 0 {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(Int(stats.lastWPM.rounded())) wpm")
                    .font(SliveTheme.mono(12))
                    .foregroundStyle(SliveTheme.accent)
                    .contentTransition(.numericText())
                Text("avg \(Int(stats.averageWPM.rounded())) · best \(Int(stats.bestWPM.rounded())) · \(stats.sampleCount) take\(stats.sampleCount == 1 ? "" : "s")")
                    .font(SliveTheme.captionFont)
                    .foregroundStyle(SliveTheme.textSecondary)
                Spacer(minLength: 0)
                Button("Reset") { stats.reset() }
                    .buttonStyle(.plain)
                    .font(SliveTheme.font(11, .semibold))
                    .foregroundStyle(SliveTheme.textDim)
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: stats.lastWPM)
        }
    }

    private var historyCard: some View {
        SettingsCard("", trailing: {
            if !history.entries.isEmpty {
                Button("Clear") { confirmClearHistory = true }
                    .buttonStyle(.plain)
                    .font(SliveTheme.font(11, .semibold))
                    .foregroundStyle(SliveTheme.accent)
            }
        }) {
            if history.entries.isEmpty {
                EmptyState(icon: "waveform", title: "Nothing in the last 24 hours.")
            } else {
                // The page scrolls — no inner scroll view.
                VStack(spacing: 0) {
                    ForEach(Array(history.entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            Divider().overlay(SliveTheme.hairline)
                        }
                        HistoryRow(entry: entry) { history.remove(entry.id) }
                    }
                }
            }
        }
        .confirmationDialog("Clear \(history.entries.count) transcript\(history.entries.count == 1 ? "" : "s")?",
                            isPresented: $confirmClearHistory) {
            Button("Clear", role: .destructive) { history.clearAll() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - History row (hover-reveal actions)

private struct HistoryRow: View {
    let entry: HistoryEntry
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text)
                    .font(SliveTheme.font(12))
                    .foregroundStyle(SliveTheme.textBright)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                Text(relativeAge(entry.createdAt))
                    .foregroundStyle(SliveTheme.textSecondary)
                    .font(SliveTheme.font(10))
            }
            Spacer(minLength: 6)
            HStack(spacing: 10) {
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(entry.text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(SliveTheme.labelFont)
                        .foregroundStyle(copied ? SliveTheme.ok : SliveTheme.textMuted)
                }
                .buttonStyle(.plain)
                .help("Copy")
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(SliveTheme.tagBoldFont)
                        .foregroundStyle(SliveTheme.textDim)
                }
                .buttonStyle(.plain)
                .help("Delete")
            }
            .opacity(hovering || copied ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// Coarse "2m ago" / "3h ago" style label.
    private func relativeAge(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = Int(seconds / 3600)
        if hours < 24 { return "\(hours)h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }

}
