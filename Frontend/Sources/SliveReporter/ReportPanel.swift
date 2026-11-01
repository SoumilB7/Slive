import AppKit
import Combine
import SliveReport
import SwiftUI

/// What the panel shows; the controller updates it live (a freeze's
/// seconds, "responding again", the report once gathered).
@MainActor
final class PanelModel: ObservableObject {
    let kind: ProblemReport.Kind
    @Published var title: String
    @Published var subtitle: String
    /// nil while the details are still being gathered.
    @Published var report: ProblemReport? {
        didSet { if let report { Self.dump(report) } }
    }

    /// Test hook: SLIVE_REPORTER_DUMP=<file> appends every finished report
    /// (title, link, body) — how the end-to-end test reads what would be sent.
    private static func dump(_ report: ProblemReport) {
        guard let path = ProcessInfo.processInfo.environment["SLIVE_REPORTER_DUMP"] else { return }
        let entry = "=== \(report.title)\n\(report.issueURL().absoluteString)\n\n\(report.markdown())\n"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(entry.utf8)); h.closeFile()
        } else {
            try? entry.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
    @Published var showDetails = false
    @Published var copied = false
    @Published var primaryTitle = "Report on GitHub"
    @Published var secondaryTitle: String?
    @Published var dismissTitle = "Not now"

    var onReport: (ProblemReport) -> Void = { _ in }
    var onSecondary: () -> Void = {}
    var onDismiss: () -> Void = {}

    init(kind: ProblemReport.Kind, title: String, subtitle: String) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
    }
}

/// A small floating card, top-right of the screen. Non-activating: it never
/// takes focus from the app you're typing in (Slive types into that app).
@MainActor
final class ReportPanel {
    let model: PanelModel
    private let panel: NSPanel
    private let host: NSHostingView<ReportCard>
    private var changes: AnyCancellable?
    /// Top-right corner the card hangs from; it grows downward.
    private var anchor: NSPoint?

    init(model: PanelModel) {
        self.model = model
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        host = NSHostingView(rootView: ReportCard(model: model))
        host.sizingOptions = []
        panel.contentView = host
        // Text and the details pane change the card's height: refit after
        // SwiftUI has applied the change.
        changes = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.fit() }
        }
    }

    func present() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            anchor = NSPoint(x: area.maxX - 16, y: area.maxY - 16)
        }
        fit()
        panel.orderFrontRegardless()
    }

    func orderFront() { panel.orderFrontRegardless() }

    func close() { panel.orderOut(nil) }

    private func fit() {
        guard let anchor else { return }
        let size = host.fittingSize
        panel.setFrame(NSRect(x: anchor.x - size.width, y: anchor.y - size.height,
                              width: size.width, height: size.height), display: true)
    }
}

// MARK: - Card

private enum Palette {
    static let accent = Color(hue: 0.50, saturation: 0.68, brightness: 0.86)
    static let amber = Color(hue: 0.11, saturation: 0.72, brightness: 0.96)
    static let red = Color(hue: 0.99, saturation: 0.58, brightness: 0.96)
    static let bgTop = Color(hue: 0.53, saturation: 0.08, brightness: 0.15)
    static let bgBottom = Color(hue: 0.53, saturation: 0.10, brightness: 0.09)
    static let text = Color.white.opacity(0.92)
    static let mid = Color.white.opacity(0.68)
    static let faint = Color.white.opacity(0.42)
    static let well = Color.white.opacity(0.06)
    static let stroke = Color.white.opacity(0.10)

    static func font(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

struct ReportCard: View {
    @ObservedObject var model: PanelModel

    private var tint: Color {
        switch model.kind {
        case .crash, .serverCrash: Palette.red
        case .hang, .failure: Palette.amber
        case .manual: Palette.accent
        }
    }

    private var symbol: String {
        switch model.kind {
        case .crash: "exclamationmark.octagon.fill"
        case .hang: "hourglass"
        case .failure: "exclamationmark.triangle.fill"
        case .serverCrash: "server.rack"
        case .manual: "ladybug.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.showDetails { details }
            actions
            Text("Opens GitHub with this filled in. Nothing is posted until you submit it there. Names, paths, device names, keys and dictated text are removed.")
                .font(Palette.font(10))
                .foregroundStyle(Palette.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
        .background(
            LinearGradient(colors: [Palette.bgTop, Palette.bgBottom], startPoint: .top, endPoint: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.stroke))
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title)
                    .font(Palette.font(13, .semibold))
                    .foregroundStyle(Palette.text)
                Text(model.subtitle)
                    .font(Palette.font(11))
                    .foregroundStyle(Palette.mid)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: model.onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.faint)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
    }

    private var details: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ScrollView {
                Text(model.report?.markdown() ?? "Gathering details…")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.mid)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 230)
            .background(Palette.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.stroke))

            Button(model.copied ? "Copied" : "Copy") {
                guard let md = model.report?.markdown() else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(md, forType: .string)
                model.copied = true
            }
            .buttonStyle(QuietButton())
            .disabled(model.report == nil)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(model.showDetails ? "Hide report" : "Show report") {
                model.showDetails.toggle()
            }
            .buttonStyle(QuietButton())

            Spacer(minLength: 0)

            if model.report == nil {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
            if let secondary = model.secondaryTitle {
                Button(secondary, action: model.onSecondary).buttonStyle(WellButton())
            }
            Button(model.primaryTitle) {
                if let report = model.report { model.onReport(report) }
            }
            .buttonStyle(PrimaryButton(tint: Palette.accent))
            .disabled(model.report == nil)
        }
    }
}

private struct PrimaryButton: ButtonStyle {
    let tint: Color
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Palette.font(12, .semibold))
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(tint.opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.35),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct WellButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Palette.font(12, .semibold))
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Palette.well.opacity(configuration.isPressed ? 2 : 1),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.stroke))
    }
}

private struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Palette.font(11, .semibold))
            .foregroundStyle(Palette.mid.opacity(configuration.isPressed ? 0.6 : 1))
            .contentShape(Rectangle())
    }
}
