import AppKit
import SwiftUI

/// Slive's home / settings screen. Doubles as the "what is this" surface:
/// a hero, a three-step explainer, the push-to-talk key picker, and live
/// permission status you can grant in place.
struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var permissions: PermissionsModel
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var transcription = TranscriptionModel.shared
    @ObservedObject private var stats = SpeakingStats.shared
    var onRelaunch: () -> Void

    private let accent = Color(hue: 0.50, saturation: 0.68, brightness: 0.86)

    /// Top-level sections: dictation (which now houses continuous as a sub-tab)
    /// vs. the LLM assistant.
    private enum Section: String, CaseIterable, Identifiable {
        case dictation = "Dictation"
        case assistant = "Assistant"
        var id: String { rawValue }
    }

    /// Sub-tabs within Dictation. `Continuous` sits right after General so the two
    /// dictation modes read as one family.
    private enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case continuous = "Continuous"
        case permissions = "Permissions"
        case vocabulary = "Vocabulary"
        case history = "History"
        var id: String { rawValue }
    }

    @State private var section: Section = .dictation
    @State private var tab: Tab = .general

    var body: some View {
        VStack(spacing: 0) {
            brandHeader
            sectionSwitcher
                .padding(.horizontal, 24)
                .padding(.bottom, 10)

            switch section {
            case .dictation:
                tabBar
                    .padding(.horizontal, 24)
                    .padding(.bottom, 4)
                ScrollView {
                    VStack(spacing: 22) {
                        switch tab {
                        case .general:
                            steps
                            speakingPaceCard
                            keyPicker
                            generalSection
                        case .continuous:
                            ContinuousSettingsView(settings: settings, accent: accent)
                        case .permissions:
                            permissionsSection
                        case .vocabulary:
                            vocabularySection
                        case .history:
                            historySection
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                }
            case .assistant:
                AssistantSettingsView(settings: settings, accent: accent)
            }

            footer
                .padding(.bottom, 16)
        }
        .frame(minWidth: 460, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        .background(background)
        .onAppear { permissions.startWatching() }
        .onDisappear { permissions.stopWatching() }
    }

    /// The top-level Dictation ↔ Assistant switch. Styled a touch larger than
    /// the sub-tab bar so the hierarchy reads clearly.
    private var sectionSwitcher: some View {
        Picker("", selection: $section) {
            ForEach(Section.allCases) { s in
                Text(s.rawValue).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.large)
    }

    private var background: some View {
        LinearGradient(
            colors: [Color(hue: 0.53, saturation: 0.08, brightness: 0.15),
                     Color(hue: 0.53, saturation: 0.10, brightness: 0.09)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    // MARK: - Brand header

    private var brandHeader: some View {
        HStack(spacing: 12) {
            BrandMark(size: 44)
            Text("Slive")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        Picker("", selection: $tab) {
            ForEach(Tab.allCases) { t in
                Text(t.rawValue).tag(t)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - How it works

    private var steps: some View {
        HStack(spacing: 10) {
            step(icon: "hand.point.up.left.fill",
                 title: "Hold", detail: settings.hotkey.label)
            arrow
            step(icon: "waveform", title: "Speak", detail: "Live waveform")
            arrow
            step(icon: "checkmark.circle.fill", title: "Release", detail: "Transcribed")
        }
    }

    private func step(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(accent)
                .frame(height: 24)
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
            Text(detail)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(card)
    }

    private var arrow: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white.opacity(0.25))
    }

    // MARK: - Speaking pace (words per minute)

    /// A live readout of how fast you've been speaking, measured after each
    /// dictation's text is written (so it never adds latency to what you type).
    @ViewBuilder private var speakingPaceCard: some View {
        let hasData = stats.sampleCount > 0
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("SPEAKING PACE")
                Spacer()
                if hasData {
                    Button("Reset") { stats.reset() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            VStack(spacing: 4) {
                SpeedometerView(value: stats.lastWPM, accent: accent)
                    .frame(maxWidth: 280)
                    .frame(height: 130)

                HStack(alignment: .lastTextBaseline, spacing: 5) {
                    Text(hasData ? "\(Int(stats.lastWPM.rounded()))" : "—")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                    Text("WPM")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(accent)
                }

                if hasData {
                    Text("Faster than \(SpeakingStats.percentile(forWPM: stats.lastWPM))% of speakers")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                    Text("avg \(Int(stats.averageWPM.rounded())) · best \(Int(stats.bestWPM.rounded())) · \(stats.sampleCount) dictation\(stats.sampleCount == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                } else {
                    Text("Speak to measure your pace — your words-per-minute appears here after each dictation.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: stats.lastWPM)
    }

    // MARK: - Key picker

    private var keyPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("PUSH-TO-TALK KEY")
            HotkeyRecorderView(accent: accent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("PERMISSIONS")
            permissionRow(
                title: "Input Monitoring",
                detail: "Detect your push-to-talk key",
                granted: permissions.inputMonitoringGranted || settings.hotkeyActive,
                action: { permissions.requestInputMonitoring() }
            )
            Divider().overlay(.white.opacity(0.08))
            permissionRow(
                title: "Microphone",
                detail: "Record your voice",
                granted: permissions.micGranted,
                action: { permissions.requestMic() }
            )
            Divider().overlay(.white.opacity(0.08))
            permissionRow(
                title: "Accessibility",
                detail: "Paste transcripts into text fields",
                granted: permissions.accessibilityGranted,
                action: { permissions.requestAccessibility() }
            )
            Divider().overlay(.white.opacity(0.08))
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundStyle(accent)
                    .font(.system(size: 16))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Just changed a permission?")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                    Text("macOS only applies it after a relaunch.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Button("Relaunch", action: onRelaunch)
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .controlSize(.small)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    private func permissionRow(title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(granted ? Color.green : Color.orange)
                .frame(width: 9, height: 9)
                .shadow(color: (granted ? Color.green : Color.orange).opacity(0.7), radius: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                Text(detail)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            if granted {
                Text("Granted")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.green)
            } else {
                Button("Grant", action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("GENERAL")
            Toggle(isOn: $settings.launchAtLogin) {
                Text("Launch at login")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .toggleStyle(.switch)
            .tint(accent)
            Toggle(isOn: $settings.autoInsert) {
                Text("Auto-insert into text fields")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .toggleStyle(.switch)
            .tint(accent)

            Divider().overlay(.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Hold delay")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer()
                    Text(String(format: "%.2fs", settings.holdActivationDelay))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accent)
                }
                Slider(value: $settings.holdActivationDelay, in: 0...0.6, step: 0.05)
                    .tint(accent)
                Text("How long to hold your key before recording starts. Shorter = snappier; longer avoids accidental taps.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Overlay opacity")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer()
                    Text("\(Int(settings.overlayOpacity * 100))%")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accent)
                }
                Slider(value: $settings.overlayOpacity, in: 0.35...1.0, step: 0.01)
                    .tint(accent)
                Text("How see-through the floating pill and answer box are. Lower blends them into what's behind; text stays readable.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(.white.opacity(0.08))

            modelPicker

            Divider().overlay(.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $settings.verboseLogging) {
                    Text("Verbose logging (developer)")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                }
                .toggleStyle(.switch)
                .tint(accent)
                Text("Emit diagnostic logs. View in Console.app or `log stream` filtered by “Slive.”. Off for normal use.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    /// On-device (Neural Engine) transcription model — accuracy vs. speed.
    private struct ModelChoice: Identifiable {
        let label: String
        let model: String
        let detail: String
        var id: String { model }
    }
    private let modelChoices: [ModelChoice] = [
        .init(label: "Tiny", model: "tiny.en", detail: "Fastest, basic accuracy · ~75 MB"),
        .init(label: "Fast", model: "base.en", detail: "Quick, good accuracy · ~150 MB"),
        .init(label: "Balanced", model: "large-v3-v20240930_626MB", detail: "Recommended — accurate & fast · ~600 MB"),
        .init(label: "Accurate", model: "large-v3", detail: "Highest accuracy, a touch slower · ~1.5 GB"),
    ]

    private var selectedModelDetail: String {
        modelChoices.first { $0.model == settings.whisperModel }?.detail
            ?? "Custom model · \(settings.whisperModel)"
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcription model")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
            HStack(spacing: 10) {
                Picker("", selection: $settings.whisperModel) {
                    ForEach(modelChoices) { c in
                        Text(c.label).tag(c.model)
                    }
                    // Keep any custom/previously-saved model selectable.
                    if !modelChoices.contains(where: { $0.model == settings.whisperModel }) {
                        Text("Custom").tag(settings.whisperModel)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(accent)
                .fixedSize()
                Text(selectedModelDetail)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
            }

            modelStatusRow

            Text("Runs on-device (Apple Neural Engine) — private and fast. A new model takes a moment to prepare the first time.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { transcription.select(settings.whisperModel) }
        .onChange(of: settings.whisperModel) { _, m in transcription.select(m) }
    }

    /// Status + Download control for the selected transcription model.
    @ViewBuilder private var modelStatusRow: some View {
        HStack(spacing: 10) {
            switch transcription.status(for: settings.whisperModel) {
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Ready").foregroundStyle(.white.opacity(0.8))
                Spacer()
                Button("Re-download") { Task { await transcription.redownload(settings.whisperModel) } }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            case .notDownloaded:
                Image(systemName: "arrow.down.circle").foregroundStyle(accent)
                Text("Not downloaded").foregroundStyle(.white.opacity(0.7))
                Spacer()
                Button("Download") {
                    Task { await transcription.download(settings.whisperModel) }
                }
                .buttonStyle(.borderedProminent).tint(accent).controlSize(.small)
            case .downloading(let p):
                ProgressView(value: p).frame(width: 120)
                Text("Downloading \(Int(p * 100))%").foregroundStyle(.white.opacity(0.7))
            case .preparing(let stage):
                ProgressView().controlSize(.small)
                Text("Preparing… (\(stage))").foregroundStyle(.white.opacity(0.7))
            case .failed(let e):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(e).foregroundStyle(.orange.opacity(0.9)).lineLimit(2)
                Spacer()
                Button("Re-download") { Task { await transcription.redownload(settings.whisperModel) } }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
    }

    // MARK: - Vocabulary

    private var vocabularySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("VOCABULARY")

            vocabularyField(
                label: "Custom words",
                hint: "Names, jargon, acronyms — space or comma separated. Helps the model spell them right.",
                text: $settings.hotwords
            )

            vocabularyField(
                label: "Context prompt",
                hint: "A sentence of context to steer transcription (optional).",
                text: $settings.contextPrompt
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    private func vocabularyField(label: String, hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
            TextEditor(text: text)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 58, maxHeight: 58)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(.white.opacity(0.10), lineWidth: 0.8)
                        )
                )
            Text(hint)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("HISTORY")
                Spacer()
                if !history.entries.isEmpty {
                    Button("Clear history") { history.clearAll() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(accent)
                }
            }

            if history.entries.isEmpty {
                Text("No transcripts yet.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(history.entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 {
                                Divider().overlay(.white.opacity(0.06))
                            }
                            historyRow(entry)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    private func historyRow(_ entry: HistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(relativeAge(entry.createdAt))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("· expires in \(expiresInHours(entry.expiresAt))")
                        .foregroundStyle(.white.opacity(0.35))
                }
                .font(.system(size: 10, weight: .medium, design: .rounded))
            }
            Spacer(minLength: 6)
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(entry.text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help("Copy")
            Button {
                history.remove(entry.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .buttonStyle(.plain)
            .help("Delete")
        }
        .padding(.vertical, 10)
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

    /// Hours remaining until expiry, rounded up, floored at 1h.
    private func expiresInHours(_ expiry: Date) -> String {
        let remaining = expiry.timeIntervalSince(Date())
        if remaining <= 0 { return "soon" }
        let hours = Int(ceil(remaining / 3600))
        return "\(max(1, hours))h"
    }

    // MARK: - Footer

    private var footer: some View {
        Text("Slive lives in your menu bar · v0.1")
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.35))
            .padding(.top, 2)
    }

    // MARK: - Shared bits

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
