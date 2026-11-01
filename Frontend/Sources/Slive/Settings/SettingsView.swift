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
    @ObservedObject private var inputDevices = InputDevices.shared
    @ObservedObject private var providers = ProviderStore.shared
    @ObservedObject private var trainingStore = TrainingStore.shared
    var onRelaunch: () -> Void

    @StateObject private var scrollKeeper = SettingsScrollKeeper()
    @State private var page: SettingsPage = .general
    /// Remembered so compact-mode section switching restores the last-visited
    /// Dictation sub-tab.
    @State private var confirmClearHistory = false
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

            // One page picker, grouped like the sidebar.
            HStack {
                Menu {
                    ForEach(SettingsSection.available) { section in
                        Section(section.rawValue) {
                            ForEach(SettingsPage.pages(in: section)) { p in
                                Button {
                                    page = p
                                } label: {
                                    Label(p.rawValue + (p == .permissions && grantedCount < 3 ? " •" : ""),
                                          systemImage: p.icon)
                                }
                            }
                        }
                    }
                } label: {
                    Label(page.rawValue, systemImage: page.icon)
                        .font(SliveTheme.rowFont)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .tint(SliveTheme.accent)
                Spacer()
            }
            .padding(.horizontal, SliveTheme.gutter)
            .padding(.bottom, 4)

            scrollContainer

            Text("v0.1")
                .font(SliveTheme.captionFont)
                .foregroundStyle(SliveTheme.textTertiary)
                .padding(.top, 2)
                .padding(.bottom, 16)
        }
    }

    // MARK: - Sidebar chrome (≥ 700pt)

    private var sidebarBody: some View {
        HStack(spacing: 0) {
            SettingsSidebar(page: $page, attention: grantedCount < 3 ? [.permissions] : [])
            scrollContainer
        }
    }

    /// THE scroll container — every page scrolls here, never internally.
    /// Pages that need to jump to an anchor (`.id(...)` on a row) get a
    /// scroll-to closure through `\.sliveScrollTo` instead of a proxy.
    private var scrollContainer: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PageTitle(title: page.rawValue, status: pageStatus.text,
                              statusColor: pageStatus.color)
                    pageContent
                }
                .frame(maxWidth: pageCap)
                .padding(.top, layout == .compact ? 20 : 44)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, SliveTheme.gutter)
                .padding(.bottom, 14)
                .background(SettingsScrollResolver { scrollKeeper.scrollView = $0 })
            }
            .environment(\.sliveScrollTo) { id in
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .environment(\.slivePreserveScroll) { change in
                scrollKeeper.applyPreservingBottomDistance(change)
            }
        }
    }

    /// Width cap for plain form pages at the current tier.
    private var formCap: CGFloat {
        layout == .compact ? .infinity : SliveTheme.formWidth
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .general: generalPage
        case .continuous: ContinuousSettingsView(settings: settings)
        case .permissions: permissionsCard
        case .vocabulary: vocabularyCard
        case .history: historyPage
        case .assistant: AssistantSettingsView(settings: settings, openModels: { page = .models })
        case .models: ModelsSettingsView(settings: settings)
        case .data: DataSettingsView(settings: settings, openModels: { page = .models })
        case .training: TrainingSettingsView(settings: settings, openData: { page = .data })
        }
    }

    /// Column width for the current page at the current tier.
    private var pageCap: CGFloat {
        switch page {
        case .general: return layout == .wide ? SliveTheme.generalGridWidth : formCap
        case .history, .models: return layout == .compact ? .infinity : SliveTheme.historyWidth
        case .data, .training: return trainingCap
        default: return formCap
        }
    }

    /// The one quiet status beside each page title.
    private var pageStatus: (text: String?, color: Color) {
        switch page {
        case .general: return (modelStatusLine(settings.whisperModel), SliveTheme.textSecondary)
        case .continuous: return (modelStatusLine(settings.continuousModel), SliveTheme.textSecondary)
        case .permissions:
            return ("\(grantedCount) of 3 granted", grantedCount == 3 ? SliveTheme.textSecondary : .orange)
        case .history:
            return (history.entries.isEmpty ? nil : "\(history.entries.count) · last 24 h", SliveTheme.textSecondary)
        case .data:
            guard trainingStore.count > 0 else { return (nil, SliveTheme.textSecondary) }
            let size = ByteCountFormatter.string(fromByteCount: trainingStore.totalBytes, countStyle: .file)
            return ("\(trainingStore.count) sample\(trainingStore.count == 1 ? "" : "s") · \(size)", SliveTheme.textSecondary)
        case .models:
            let n = [AssistantProvider.anthropic, .openai, .gemini, .openaiCompatible]
                .filter { providers.hasKey($0) }.count
            return (n > 0 ? "\(n) connected" : "None connected", n > 0 ? SliveTheme.textSecondary : .orange)
        default: return (nil, SliveTheme.textSecondary)
        }
    }

    /// "Parakeet – Ultra · Ready" for a dictation model id.
    private func modelStatusLine(_ model: String) -> String {
        let name = (WhisperModelChoice.all + WhisperModelChoice.parakeet).first { $0.model == model }?.label
            ?? transcription.customModels.first { $0.id == model }?.displayName
            ?? model
        let state: String
        switch transcription.status(for: model) {
        case .ready: state = "Ready"
        case .downloading: state = "Downloading"
        case .preparing: state = "Loading"
        case .failed: state = "Failed"
        case .notDownloaded: state = "Not downloaded"
        }
        return "\(name) · \(state)"
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
                // Setup on the left, model and mic on the right, the speed
                // graph full width below.
                VStack(spacing: SliveTheme.cardGap) {
                    HStack(alignment: .top, spacing: SliveTheme.gridGap) {
                        VStack(spacing: SliveTheme.cardGap) {
                            keyCard
                            liveTypingSuggestion
                            behaviorCard
                        }
                        VStack(spacing: SliveTheme.cardGap) {
                            modelCard
                            micCard
                            overlayCard
                        }
                    }
                    speedCard
                }
            } else {
                VStack(spacing: SliveTheme.cardGap) {
                    keyCard
                    liveTypingSuggestion
                    modelCard
                    micCard
                    behaviorCard
                    overlayCard
                    speedCard
                }
            }
        }
        .onAppear { transcription.select(settings.whisperModel) }
        .onChange(of: settings.whisperModel) { _, m in transcription.select(m) }
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
                    .foregroundStyle(.white.opacity(0.45))
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: stats.lastWPM)
        }
    }

    // MARK: Push-to-talk key

    private var keyCard: some View {
        SettingsCard("KEYS") {
            // Hold: press-and-speak. Its switch can turn the hold bind off
            // entirely (toggle-only users).
            HStack(alignment: .center, spacing: 12) {
                HotkeyRecorderView(target: .dictation, title: "Hold to talk")
                    .opacity(settings.dictateHoldOn ? 1 : 0.45)
                Toggle("", isOn: $settings.dictateHoldOn)
                    .labelsHidden().toggleStyle(.switch).tint(SliveTheme.accent)
            }
            CardDivider()
            // Toggle: tap to start, tap again to stop.
            HStack(alignment: .center, spacing: 12) {
                HotkeyRecorderView(target: .dictationToggle, title: "Tap to toggle")
                    .opacity(settings.dictateToggleOn ? 1 : 0.45)
                Toggle("", isOn: $settings.dictateToggleOn)
                    .labelsHidden().toggleStyle(.switch).tint(SliveTheme.accent)
            }
        }
    }

    // MARK: Live typing suggestion

    @AppStorage("liveTypingSuggestionDismissed") private var liveTypingDismissed = false

    /// Live typing is a choice, so it starts off — but suggested once, with
    /// the shortcuts Soumil uses. Gone when either shortcut is set or dismissed.
    @ViewBuilder private var liveTypingSuggestion: some View {
        if settings.streamHotkey == nil, settings.streamToggleHotkey == nil, !liveTypingDismissed {
            SettingsCard("LIVE TYPING") {
                Text("Types while you speak. Hold ⌥ / or tap ⌥ . to start and stop.")
                    .font(SliveTheme.captionFont)
                    .foregroundStyle(SliveTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Turn on") {
                        settings.streamHotkey = Settings.suggestedStreamHotkey
                        settings.streamToggleHotkey = Settings.suggestedStreamToggleHotkey
                        let model = settings.continuousModel
                        if !transcription.isDownloaded(model) {
                            Task { await transcription.download(model) }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SliveTheme.accent)
                    .controlSize(.small)
                    Button("Not now") { liveTypingDismissed = true }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: Transcription model

    private var modelCard: some View {
        ModelPickerCard(
            title: "MODEL",
            model: $settings.whisperModel,
            help: "Runs on this Mac",
            includeParakeet: true,
            suggestBalanced: true
        )
    }

    // MARK: Microphone

    /// The chosen mic, if it's connected right now.
    private var chosenMic: InputDevices.Device? {
        inputDevices.device(forUID: settings.inputDeviceUID)
    }

    /// Meet-style mic menu: system default first (named, so you know what
    /// "default" means today), then every connected input. Applies to hold
    /// AND continuous dictation from the next recording.
    private var micCard: some View {
        SettingsCard("MICROPHONE") {
            HStack(spacing: 10) {
                Picker("", selection: $settings.inputDeviceUID) {
                    Text("System default" + (inputDevices.systemDefault.map { " · \($0.name)" } ?? ""))
                        .tag("")
                    if !inputDevices.devices.isEmpty { Divider() }
                    ForEach(inputDevices.devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                    // A saved pick that isn't plugged in stays selectable so
                    // it takes effect again the moment it returns.
                    if !settings.inputDeviceUID.isEmpty && chosenMic == nil {
                        Text("\(settings.inputDeviceName.isEmpty ? "Chosen mic" : settings.inputDeviceName) (not connected)")
                            .tag(settings.inputDeviceUID)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(SliveTheme.accent)
                .fixedSize()
                .help("Used for dictation and live typing")
                .onChange(of: settings.inputDeviceUID) { _, uid in
                    settings.inputDeviceName = inputDevices.device(forUID: uid)?.name ?? ""
                }
                micDetail
                Spacer(minLength: 0)
            }
            if settings.echoCancellation {
                // The canceller needs the speaker signal, so it follows the
                // system default route and the pick above is ignored.
                HStack(spacing: 8) {
                    Text("Echo cancellation uses the system mic.")
                        .font(SliveTheme.captionFont)
                        .foregroundStyle(Color.orange)
                    Button("Turn off") { settings.echoCancellation = false }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            } else if activeMic?.transport == "Bluetooth" {
                // Opening a Bluetooth mic drops headphones to call quality.
                Text("Pick Built-in to keep music quality.")
                    .sliveCaption()
            }
            CardDivider()
            ToggleRow(title: "Echo cancellation", isOn: $settings.echoCancellation)
                .help("Removes speaker sound from the mic. May pop on start.")
        }
    }

    /// The mic recording will actually open (the pick, or the default).
    private var activeMic: InputDevices.Device? {
        chosenMic ?? (settings.inputDeviceUID.isEmpty ? inputDevices.systemDefault : nil)
    }

    @ViewBuilder private var micDetail: some View {
        if let mic = activeMic {
            Text(mic.detail)
                .font(SliveTheme.captionFont)
                .foregroundStyle(.white.opacity(0.55))
        } else if !settings.inputDeviceUID.isEmpty {
            Text("Not connected · using \(inputDevices.systemDefault?.name ?? "system default")")
                .font(SliveTheme.captionFont)
                .foregroundStyle(Color.orange)
        }
    }

    // MARK: Behavior

    /// What you see: where the pill sits (the preview is the control), how
    /// solid it is, and whether results type in or show in the overlay.
    private var overlayCard: some View {
        SettingsCard("OVERLAY") {
            HStack(alignment: .center, spacing: 20) {
                PillPositionPicker(settings: settings)
                VStack(alignment: .leading, spacing: 12) {
                    ToggleRow(title: "Type at cursor", isOn: $settings.autoInsert)
                        .help("Off: shows text in the overlay")
                    CardDivider()
                    SliderRow(
                        title: "Opacity",
                        value: $settings.overlayOpacity,
                        range: 0.35...1.0, step: 0.01,
                        valueText: "\(Int(settings.overlayOpacity * 100))%"
                    )
                }
            }
        }
    }

    private var behaviorCard: some View {
        SettingsCard("BEHAVIOR") {
            SliderRow(
                title: "Hold delay",
                value: $settings.holdActivationDelay,
                range: 0...0.6, step: 0.05,
                valueText: String(format: "%.2fs", settings.holdActivationDelay)
            )
            .help("Wait before recording starts")
            CardDivider()
            ToggleRow(title: "Launch at login", isOn: $settings.launchAtLogin)
            CardDivider()
            ToggleRow(title: "Developer logs", isOn: $settings.verboseLogging)
                .help("Console.app · filter Slive")
        }
    }

    // MARK: Speed

    /// The latency ⇄ resources tradeoff, as a clickable graph: pick the
    /// latency you want, see what it spends.
    private var speedCard: some View {
        SettingsCard("SPEED") {
            LatencyGraphView(settings: settings)
                .help("Lower latency keeps more in memory")
        }
    }

    // MARK: - Dictation · Permissions

    private var grantedCount: Int {
        [permissions.inputMonitoringGranted || settings.hotkeyActive,
         permissions.micGranted,
         permissions.accessibilityGranted].filter { $0 }.count
    }

    private var permissionsCard: some View {
        SettingsCard("") {
            permissionRow(
                title: "Input Monitoring",
                detail: "Detects your shortcut",
                granted: permissions.inputMonitoringGranted || settings.hotkeyActive,
                action: { permissions.requestInputMonitoring() }
            )
            CardDivider()
            permissionRow(
                title: "Microphone",
                detail: "Hears you",
                granted: permissions.micGranted,
                action: { permissions.requestMic() }
            )
            CardDivider()
            permissionRow(
                title: "Accessibility",
                detail: "Types into apps",
                granted: permissions.accessibilityGranted,
                action: { permissions.requestAccessibility() }
            )
            CardDivider()
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundStyle(SliveTheme.accent)
                    .font(.system(size: 14))
                Text("Applies after relaunch.")
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
        SettingsCard("") {
            if layout == .wide {
                HStack(alignment: .top, spacing: 16) {
                    VocabularyField(label: "Custom words", hint: "One per line",
                                    height: 96, text: $settings.hotwords)
                    VocabularyField(label: "Context prompt", hint: "Context for labels",
                                    height: 96, text: $settings.contextPrompt)
                }
            } else {
                VocabularyField(label: "Custom words", hint: "One per line",
                                height: 96, text: $settings.hotwords)
                VocabularyField(label: "Context prompt", hint: "Context for labels",
                                height: 72, text: $settings.contextPrompt)
            }
        }
    }

    // MARK: - Dictation · History

    private var historyPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            paceLine
            historyCard
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
                            Divider().overlay(.white.opacity(0.06))
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

/// Finds SwiftUI's root NSScrollView without creating a second scrolling
/// region. The weak reference is refreshed whenever SwiftUI rebuilds the host.
private struct SettingsScrollResolver: NSViewRepresentable {
    let resolve: (NSScrollView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { resolveFrom(view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { resolveFrom(view) }
    }

    private func resolveFrom(_ view: NSView) {
        if let scrollView = view.enclosingScrollView {
            resolve(scrollView)
        }
    }
}

/// Keeps pagination feeling like replacing the current sheet of rows instead
/// of teleporting through one giant document. AppKit is used here because the
/// project targets macOS 14, before SwiftUI exposed scroll geometry.
private final class SettingsScrollKeeper: ObservableObject {
    weak var scrollView: NSScrollView?

    func applyPreservingBottomDistance(_ change: @escaping () -> Void) {
        guard let scrollView,
              let documentView = scrollView.documentView else {
            change()
            return
        }

        let viewportHeight = scrollView.contentView.bounds.height
        let oldMaximum = max(0, documentView.bounds.height - viewportHeight)
        let oldOffset = min(max(0, scrollView.contentView.bounds.origin.y), oldMaximum)
        let distanceFromBottom = oldMaximum - oldOffset

        change()

        // First hop lets @State replace the page; the second lets SwiftUI lay
        // out rows whose wrapped text can give the new page a different height.
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async {
                guard let scrollView = self?.scrollView,
                      let documentView = scrollView.documentView else { return }
                let newMaximum = max(
                    0, documentView.bounds.height - scrollView.contentView.bounds.height)
                let newOffset = max(0, newMaximum - distanceFromBottom)
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: newOffset))
                scrollView.reflectScrolledClipView(scrollView.contentView)
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
        }
        .help(hint)
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

}
