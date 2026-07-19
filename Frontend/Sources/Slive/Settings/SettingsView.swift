import AppKit
import SwiftUI

/// Slive's home / settings window root. Owns navigation and the single scroll
/// container for every page, and adapts to the window width:
/// - compact (< 700pt): stacked segmented chrome, cards fill the width
/// - regular (≥ 700pt): themed sidebar + centered width-capped columns
/// - wide (≥ 1100pt): sidebar + wide treatments (General grid, wide Data table)
struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var permissions: PermissionsModel
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var transcription = TranscriptionModel.shared
    @ObservedObject private var stats = SpeakingStats.shared
    var onRelaunch: () -> Void

    @State private var page: SettingsPage = .general
    /// Remembered so compact-mode section switching restores the last-visited
    /// Dictation sub-tab.
    @State private var lastDictationPage: SettingsPage = .general
    /// Seeded from the autosaved window frame so the first frame renders in the
    /// right tier (a compact-restored window shouldn't flash one sidebar frame
    /// before onGeometryChange reports). Format: "x y w h screenX …" — width is
    /// the third token; any parse failure falls back to the default size.
    @State private var width: CGFloat = {
        if let frame = UserDefaults.standard.string(forKey: "NSWindow Frame SliveSettings") {
            let tokens = frame.split(separator: " ")
            if tokens.count > 2, let w = Double(tokens[2]), w > 0 {
                return CGFloat(w)
            }
        }
        return SliveTheme.windowDefault.width
    }()

    private var layout: SliveLayout { SliveLayout.tier(for: width) }

    var body: some View {
        Group {
            if layout == .compact {
                compactBody
            } else {
                sidebarBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SliveTheme.background.ignoresSafeArea())
        .environment(\.sliveLayout, layout)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .onChange(of: page) { _, p in
            if p.section == .dictation { lastDictationPage = p }
        }
        .onAppear { permissions.startWatching() }
        .onDisappear { permissions.stopWatching() }
    }

    // MARK: - Compact chrome (< 700pt — today's stacked navigation)

    private var compactBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                BrandMark(size: 28)
                Text("Slive")
                    .font(SliveTheme.font(15, .semibold))
                    .foregroundStyle(SliveTheme.textPrimary)
                WhisperStatusDot()
                Spacer()
            }
            .padding(.horizontal, SliveTheme.gutter)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Picker("", selection: sectionBinding) {
                ForEach(SettingsSection.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .padding(.horizontal, SliveTheme.gutter)
            .padding(.bottom, 10)

            if page.section == .dictation {
                Picker("", selection: $page) {
                    ForEach(SettingsPage.pages(in: .dictation)) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, SliveTheme.gutter)
                .padding(.bottom, 4)
            }

            scrollContainer

            Text("Slive lives in your menu bar · v0.1")
                .font(SliveTheme.captionFont)
                .foregroundStyle(SliveTheme.textTertiary)
                .padding(.top, 2)
                .padding(.bottom, 16)
        }
    }

    /// Compact section switch: entering Dictation restores the last sub-tab.
    private var sectionBinding: Binding<SettingsSection> {
        Binding(
            get: { page.section },
            set: { s in
                page = s == .dictation ? lastDictationPage : SettingsPage.first(in: s)
            }
        )
    }

    // MARK: - Sidebar chrome (≥ 700pt)

    private var sidebarBody: some View {
        HStack(spacing: 0) {
            SettingsSidebar(page: $page)
            scrollContainer
        }
    }

    /// THE scroll container — every page scrolls here, never internally.
    /// Pages that need to jump to an anchor (`.id(...)` on a row) get a
    /// scroll-to closure through `\.sliveScrollTo` instead of a proxy.
    private var scrollContainer: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    pageContent
                        .padding(.top, layout == .compact ? 20 : 44)
                        .frame(maxWidth: .infinity)
                    signoff
                }
                .padding(.horizontal, SliveTheme.gutter)
                .padding(.bottom, 14)
            }
            .environment(\.sliveScrollTo) { id in
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    /// The brand sign-off, bottom-right of every page.
    private var signoff: some View {
        Text("Your whisper, truly yours.")
            .font(SliveTheme.font(11, .medium))
            .italic()
            .foregroundStyle(SliveTheme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 26)
    }

    /// Width cap for plain form pages at the current tier.
    private var formCap: CGFloat {
        layout == .compact ? .infinity : SliveTheme.formWidth
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .general:
            generalPage
        case .continuous:
            ContinuousSettingsView(settings: settings)
                .frame(maxWidth: formCap)
        case .permissions:
            permissionsCard
                .frame(maxWidth: formCap)
        case .vocabulary:
            vocabularyCard
                .frame(maxWidth: formCap)
        case .history:
            historyCard
                .frame(maxWidth: layout == .compact ? .infinity : SliveTheme.historyWidth)
        case .assistant:
            AssistantSettingsView(settings: settings, openModels: { page = .models })
                .frame(maxWidth: formCap)
        case .models:
            ModelsSettingsView(settings: settings)
                .frame(maxWidth: layout == .compact ? .infinity : SliveTheme.historyWidth)
        case .data:
            DataSettingsView(settings: settings, openModels: { page = .models })
                .frame(maxWidth: trainingCap)
        case .training:
            TrainingSettingsView(settings: settings, openData: { page = .data })
                .frame(maxWidth: trainingCap)
        }
    }

    /// Data may grow past the form cap — its table earns real width.
    private var trainingCap: CGFloat {
        switch layout {
        case .compact: return .infinity
        case .regular: return SliveTheme.tableWidthRegular
        case .wide: return SliveTheme.tableWidthWide
        }
    }

    // MARK: - Dictation · General

    @ViewBuilder private var generalPage: some View {
        Group {
            if layout == .wide {
                // 880pt grid: pace hero full width, then two two-up rows.
                VStack(spacing: SliveTheme.cardGap) {
                    speakingPaceCard
                    speedCard
                    HStack(alignment: .top, spacing: SliveTheme.gridGap) {
                        keyCard
                        modelCard
                    }
                    HStack(alignment: .top, spacing: SliveTheme.gridGap) {
                        behaviorCard
                        advancedCard
                    }
                }
                .frame(maxWidth: SliveTheme.generalGridWidth)
            } else {
                VStack(spacing: SliveTheme.cardGap) {
                    speakingPaceCard
                    speedCard
                    keyCard
                    modelCard
                    behaviorCard
                    advancedCard
                }
                .frame(maxWidth: formCap)
            }
        }
        .onAppear { transcription.select(settings.whisperModel) }
        .onChange(of: settings.whisperModel) { _, m in transcription.select(m) }
    }

    // MARK: Speaking pace (words per minute)

    /// A live readout of how fast you've been speaking, measured after each
    /// dictation's text is written (so it never adds latency to what you type).
    private var speakingPaceCard: some View {
        let hasData = stats.sampleCount > 0
        return SettingsCard("SPEAKING PACE", trailing: {
            if hasData {
                Button("Reset") { stats.reset() }
                    .buttonStyle(.plain)
                    .font(SliveTheme.font(11, .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }) {
            if layout == .wide {
                // Horizontal hero: dial left, numbers right.
                HStack(spacing: 26) {
                    SpeedometerView(value: stats.lastWPM, accent: SliveTheme.accent)
                        .frame(width: 220, height: 110)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .lastTextBaseline, spacing: 6) {
                            Text(hasData ? "\(Int(stats.lastWPM.rounded()))" : "—")
                                .font(SliveTheme.font(40, .bold))
                                .foregroundStyle(.white)
                                .contentTransition(.numericText())
                            Text("WPM")
                                .font(SliveTheme.font(13, .bold))
                                .foregroundStyle(SliveTheme.accent)
                        }
                        if hasData {
                            HStack(spacing: 22) {
                                paceStat("AVG", "\(Int(stats.averageWPM.rounded()))")
                                paceStat("BEST", "\(Int(stats.bestWPM.rounded()))")
                                paceStat("TAKES", "\(stats.sampleCount)")
                            }
                        } else {
                            Text("Talk to me — your words-per-minute lands here after every take.")
                                .font(SliveTheme.font(12))
                                .foregroundStyle(SliveTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
            } else {
                VStack(spacing: 4) {
                    SpeedometerView(value: stats.lastWPM, accent: SliveTheme.accent)
                        .frame(width: 260, height: 122)

                    HStack(alignment: .lastTextBaseline, spacing: 5) {
                        Text(hasData ? "\(Int(stats.lastWPM.rounded()))" : "—")
                            .font(SliveTheme.font(34, .bold))
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                        Text("WPM")
                            .font(SliveTheme.font(13, .bold))
                            .foregroundStyle(SliveTheme.accent)
                    }

                    if hasData {
                        Text("avg \(Int(stats.averageWPM.rounded())) · best \(Int(stats.bestWPM.rounded())) · \(stats.sampleCount) dictation\(stats.sampleCount == 1 ? "" : "s")")
                            .font(SliveTheme.captionFont)
                            .foregroundStyle(.white.opacity(0.45))
                    } else {
                        Text("Talk to me — your words-per-minute lands here after every take.")
                            .font(SliveTheme.font(12))
                            .foregroundStyle(SliveTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: stats.lastWPM)
    }

    private func paceStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(SliveTheme.font(10, .bold))
                .foregroundStyle(SliveTheme.textTertiary)
                .tracking(0.8)
            Text(value)
                .font(SliveTheme.font(15, .semibold))
                .foregroundStyle(SliveTheme.textPrimary)
        }
    }

    // MARK: Push-to-talk key

    private var keyCard: some View {
        SettingsCard("PUSH-TO-TALK KEY") {
            HotkeyRecorderView(target: .dictation)
            CardDivider()
            StepsRibbon(steps: [
                .init(icon: "hand.point.up.left.fill", text: "Hold",
                      key: settings.hotkey.label),
                .init(icon: "waveform", text: "Speak"),
                .init(icon: "checkmark.circle.fill", text: "Release to type"),
            ])
        }
    }

    // MARK: Transcription model

    private var modelCard: some View {
        ModelPickerCard(
            title: "TRANSCRIPTION MODEL",
            model: $settings.whisperModel,
            footnote: "Runs right on the Neural Engine — fast, and nothing ever leaves your Mac. A fresh model takes a moment to warm up the first time."
        )
    }

    // MARK: Behavior

    private var behaviorCard: some View {
        SettingsCard("BEHAVIOR") {
            ToggleRow(title: "Auto-insert into text fields", isOn: $settings.autoInsert)
            CardDivider()
            SliderRow(
                title: "Hold delay",
                value: $settings.holdActivationDelay,
                range: 0...0.6, step: 0.05,
                valueText: String(format: "%.2fs", settings.holdActivationDelay),
                caption: "The beat between press and record. Short feels instant; long shrugs off accidental taps."
            )
            CardDivider()
            SliderRow(
                title: "Overlay opacity",
                value: $settings.overlayOpacity,
                range: 0.35...1.0, step: 0.01,
                valueText: "\(Int(settings.overlayOpacity * 100))%",
                caption: "Ghost the pill into your wallpaper, or keep it bold — readable either way."
            )
            CardDivider()
            ToggleRow(title: "Launch at login", isOn: $settings.launchAtLogin)
        }
    }

    // MARK: Advanced

    /// The latency ⇄ resources tradeoff, as a clickable graph: pick the
    /// latency you want, see exactly what it spends.
    private var speedCard: some View {
        SettingsCard("SPEED ⇄ RESOURCES") {
            Text("Click the latency you want. Lower latency pins more in RAM and holds the machine at speed — the receipt below says exactly what your pick spends.")
                .sliveCaption()
            LatencyGraphView(settings: settings)
        }
    }

    private var advancedCard: some View {
        SettingsCard("ADVANCED") {
            ToggleRow(
                title: "Echo cancellation (open mic)",
                caption: "Walls off whatever your speakers are blasting so it never leaks into the mic — the same canceller FaceTime uses. It can pop for a moment when recording starts on some Macs, so leave it off unless speaker bleed is wrecking your transcripts.",
                isOn: $settings.echoCancellation
            )
            CardDivider()
            ToggleRow(
                title: "Save dictation recordings (training data)",
                caption: "Slive keeps every take — the audio and what it heard — so it can learn how you really talk. Stays on your Mac, always.",
                isOn: $settings.captureEdits
            )
            CardDivider()
            ToggleRow(
                title: "Verbose logging (developer)",
                caption: "Spills diagnostic logs when you're chasing a bug — read them in Console.app or `log stream`, filtered by “Slive.”. Leave it off otherwise.",
                isOn: $settings.verboseLogging
            )
        }
    }

    // MARK: - Dictation · Permissions

    private var grantedCount: Int {
        [permissions.inputMonitoringGranted || settings.hotkeyActive,
         permissions.micGranted,
         permissions.accessibilityGranted].filter { $0 }.count
    }

    private var permissionsCard: some View {
        SettingsCard("PERMISSIONS", trailing: {
            Text("\(grantedCount) of 3 granted")
                .font(SliveTheme.font(11, .semibold))
                .foregroundStyle(grantedCount == 3 ? Color.green : Color.orange)
        }) {
            permissionRow(
                title: "Input Monitoring",
                detail: "So Slive can feel your push-to-talk key",
                granted: permissions.inputMonitoringGranted || settings.hotkeyActive,
                action: { permissions.requestInputMonitoring() }
            )
            CardDivider()
            permissionRow(
                title: "Microphone",
                detail: "So Slive can hear your voice",
                granted: permissions.micGranted,
                action: { permissions.requestMic() }
            )
            CardDivider()
            permissionRow(
                title: "Accessibility",
                detail: "So Slive can type into whatever field you're in",
                granted: permissions.accessibilityGranted,
                action: { permissions.requestAccessibility() }
            )
            CardDivider()
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundStyle(SliveTheme.accent)
                    .font(.system(size: 14))
                Text("macOS only notices permission changes after a relaunch.")
                    .sliveCaption()
                Spacer()
                Button("Relaunch", action: onRelaunch)
                    .buttonStyle(.bordered)
                    .tint(SliveTheme.accent)
                    .controlSize(.small)
            }
        }
    }

    private func permissionRow(title: String, detail: String, granted: Bool,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            StatusDot(color: granted ? .green : .orange, pulses: !granted, size: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SliveTheme.rowFont)
                    .foregroundStyle(SliveTheme.textPrimary)
                Text(detail).sliveCaption()
            }
            Spacer()
            if granted {
                Text("Granted")
                    .font(SliveTheme.font(12, .semibold))
                    .foregroundStyle(.green)
            } else {
                Button("Grant", action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(SliveTheme.accent)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Dictation · Vocabulary

    private var vocabularyCard: some View {
        SettingsCard("VOCABULARY") {
            if layout == .wide {
                HStack(alignment: .top, spacing: 16) {
                    VocabularyField(
                        label: "Custom words",
                        hint: "Names, jargon, acronyms — comma or space between them. So Slive spells your world right.",
                        height: 96, text: $settings.hotwords)
                    VocabularyField(
                        label: "Context prompt",
                        hint: "A line of context to nudge transcription your way. Totally optional.",
                        height: 96, text: $settings.contextPrompt)
                }
            } else {
                VocabularyField(
                    label: "Custom words",
                    hint: "Names, jargon, acronyms — comma or space between them. So Slive spells your world right.",
                    height: 96, text: $settings.hotwords)
                VocabularyField(
                    label: "Context prompt",
                    hint: "A line of context to nudge transcription your way. Totally optional.",
                    height: 72, text: $settings.contextPrompt)
            }
        }
    }

    // MARK: - Dictation · History

    private var historyCard: some View {
        SettingsCard("HISTORY", trailing: {
            HStack(spacing: 12) {
                if !history.entries.isEmpty {
                    Text("\(history.entries.count) · last 24 h")
                        .font(SliveTheme.captionFont)
                        .foregroundStyle(SliveTheme.textTertiary)
                    Button("Clear history") { history.clearAll() }
                        .buttonStyle(.plain)
                        .font(SliveTheme.font(11, .semibold))
                        .foregroundStyle(SliveTheme.accent)
                }
            }
        }) {
            if history.entries.isEmpty {
                EmptyState(
                    icon: "waveform",
                    title: "No transcripts yet",
                    caption: "Everything you've said in the last 24 hours waits here."
                )
            } else {
                // The page scrolls — no inner scroll view.
                VStack(spacing: 0) {
                    ForEach(Array(history.entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            Divider().overlay(.white.opacity(0.06))
                        }
                        HistoryRow(entry: entry) { history.remove(entry.id) }
                    }
                }
            }
        }
    }
}

// MARK: - Vocabulary field (focus ring on the well)

private struct VocabularyField: View {
    let label: String
    let hint: String
    let height: CGFloat
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(SliveTheme.rowFont)
                .foregroundStyle(SliveTheme.textPrimary)
            TextEditor(text: $text)
                .font(SliveTheme.font(12))
                .foregroundStyle(.white.opacity(0.9))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: height)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(SliveTheme.wellFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    focused ? SliveTheme.accent.opacity(0.5) : SliveTheme.wellStroke,
                                    lineWidth: focused ? 1 : 0.8)
                        )
                )
                .focused($focused)
                .animation(.easeOut(duration: 0.15), value: focused)
            Text(hint).sliveCaption()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(relativeAge(entry.createdAt))
                        .foregroundStyle(SliveTheme.textSecondary)
                    Text("· expires in \(expiresInHours(entry.expiresAt))")
                        .foregroundStyle(SliveTheme.textTertiary)
                }
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
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(copied ? Color.green : .white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help("Copy")
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.45))
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

    /// Hours remaining until expiry, rounded up, floored at 1h.
    private func expiresInHours(_ expiry: Date) -> String {
        let remaining = expiry.timeIntervalSince(Date())
        if remaining <= 0 { return "soon" }
        let hours = Int(ceil(remaining / 3600))
        return "\(max(1, hours))h"
    }
}
