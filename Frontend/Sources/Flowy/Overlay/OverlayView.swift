import SwiftUI
import AppKit

/// Shared geometry for the overlay. Both the SwiftUI view (content) and the
/// AppKit controller (NSPanel frame) size themselves from these numbers so the
/// grown box and the window that hosts it stay in lock-step.
enum OverlayMetrics {
    /// The resting pill container (also the shadow-spill container size).
    static let pillSize = CGSize(width: 120, height: 44)

    static let fontSize: CGFloat = 14
    static let maxBoxWidth: CGFloat = 420      // widest the result box may grow
    static let maxBoxHeight: CGFloat = 340     // tallest before the text scrolls
    static let hInset: CGFloat = 14            // text padding inside the box
    static let vInset: CGFloat = 10
    static let margin: CGFloat = 14            // transparent container padding (shadow room)
    static let minBoxHeight: CGFloat = 30
    static let cornerRadius: CGFloat = 14

    static let copyButtonWidth: CGFloat = 16   // width reserved for the copy button
    static let copyGap: CGFloat = 8            // gap between text and copy button

    /// Total horizontal room the copy button (plus its gap) claims inside the box.
    static let copyReserve: CGFloat = copyButtonWidth + copyGap

    /// Font used for both rendering (SwiftUI) and measurement (AppKit).
    static func roundedFont(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        if let d = base.fontDescriptor.withDesign(.rounded) {
            return NSFont(descriptor: d, size: size) ?? base
        }
        return base
    }

    /// The black box's own size for a given transcript, wrapped at `maxBoxWidth`.
    static func boxSize(for text: String) -> CGSize {
        let font = roundedFont(size: fontSize)
        // The copy button (plus its gap) eats into the text column, so measure
        // the text against the narrower width and add the reserve back below.
        let maxTextW = maxBoxWidth - hInset * 2 - copyReserve
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: maxTextW, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        // +1 guards against SwiftUI/AppKit rounding disagreements that would clip
        // the last glyph and force an unwanted extra wrap.
        let w = min(maxBoxWidth, ceil(bounds.width) + hInset * 2 + copyReserve + 1)
        // Cap the height: taller answers scroll inside the box instead of growing
        // off-screen.
        let h = min(maxBoxHeight, max(minBoxHeight, ceil(bounds.height) + vInset * 2))
        return CGSize(width: w, height: h)
    }

    /// The container (and NSPanel) size for a result box — box plus shadow margin.
    static func panelSize(for text: String) -> CGSize {
        let b = boxSize(for: text)
        return CGSize(width: b.width + margin * 2, height: b.height + margin * 2)
    }
}

/// A tiny, quiet black pill that sits just above the bottom edge. It shows a
/// live waveform while recording, a loading indicator while transcribing, and
/// grows into a rounded box to show the returned text.
struct OverlayView: View {
    @ObservedObject var model: AudioModel

    /// Retained across the fade-out so the box doesn't collapse mid-animation.
    @State private var displayText: String = ""

    private var isListening: Bool {
        if case .listening = model.phase { return true }; return false
    }
    private var isTranscribing: Bool {
        if case .transcribing = model.phase { return true }; return false
    }
    private var isResult: Bool {
        if case .result = model.phase { return true }; return false
    }

    private var resultText: String {
        if case .result(let t) = model.phase { return t }
        return displayText
    }

    private var containerSize: CGSize {
        if case .result(let t) = model.phase { return OverlayMetrics.panelSize(for: t) }
        return OverlayMetrics.pillSize
    }

    var body: some View {
        ZStack {
            listeningPill
                .opacity(isListening ? 1 : 0)
                .scaleEffect(isListening ? 1 : 0.9)

            transcribingPill(active: isTranscribing)
                .opacity(isTranscribing ? 1 : 0)
                .scaleEffect(isTranscribing ? 1 : 0.9)

            resultBox(resultText)
                .opacity(isResult ? 1 : 0)
                .scaleEffect(isResult ? 1 : 0.92)
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: model.phase)
        // Click-through everywhere except while the result box is showing, so its
        // copy button can be clicked; the pill/transcribing states stay passive.
        .allowsHitTesting(isResult)
        .onChange(of: model.phase) { _, newPhase in
            if case .result(let t) = newPhase { displayText = t }
        }
    }

    // MARK: - Listening (unchanged waveform pill)

    private var listeningPill: some View {
        WaveformView(levels: model.levels)
            .frame(width: 48, height: 18)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.92)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.40), radius: 6, y: 2)
    }

    // MARK: - Transcribing (loading dots in the same pill)

    private func transcribingPill(active: Bool) -> some View {
        LoadingDots(active: active)
            .frame(width: 48, height: 18)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.92)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.40), radius: 6, y: 2)
    }

    // MARK: - Result (grown box, sized to the text)

    private func resultBox(_ text: String) -> some View {
        let box = OverlayMetrics.boxSize(for: text)
        // Text column is the box minus its padding, the button, and the gap.
        let textWidth = box.width - OverlayMetrics.hInset * 2
            - OverlayMetrics.copyReserve
        return ScrollView(.vertical, showsIndicators: true) {
            Text(text)
                .font(.system(size: OverlayMetrics.fontSize, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
                .multilineTextAlignment(.leading)
                .lineSpacing(1)
                .textSelection(.enabled)
                .frame(width: textWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, OverlayMetrics.hInset)
                .padding(.vertical, OverlayMetrics.vInset)
        }
            .frame(width: box.width, height: box.height, alignment: .topLeading)
            // Copy button pinned to the top-right so it stays put as text scrolls.
            .overlay(alignment: .topTrailing) {
                CopyButton(text: text)
                    .padding(.top, OverlayMetrics.vInset)
                    .padding(.trailing, OverlayMetrics.hInset)
            }
            .background(
                RoundedRectangle(cornerRadius: OverlayMetrics.cornerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: OverlayMetrics.cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: OverlayMetrics.cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.40), radius: 8, y: 3)
    }
}

/// A small, subtle copy affordance beside the transcript. Copies the text to
/// the general pasteboard and briefly flips to a checkmark to confirm. Uses a
/// plain SwiftUI `Button`, which — inside a non-activating panel — copies
/// without stealing focus from the app the user is dictating into.
private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(copied ? 0.9 : 0.7))
                .frame(width: OverlayMetrics.copyButtonWidth, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy")
    }
}

/// Three gently pulsing dots — a quiet "working on it" cue. Self-contained
/// (independent of the audio meter). Redraws pause when `active` is false.
private struct LoadingDots: View {
    var active: Bool

    private let dotColor = Color(hue: 0.52, saturation: 0.55, brightness: 0.9)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = sin(t * 3.2 - Double(i) * 0.8) * 0.5 + 0.5   // 0…1
                    Circle()
                        .fill(dotColor.opacity(0.45 + 0.55 * phase))
                        .frame(width: 5, height: 5)
                        .scaleEffect(0.7 + 0.4 * phase)
                }
            }
        }
    }
}
