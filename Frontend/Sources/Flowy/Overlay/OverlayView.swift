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

    static let copyButtonWidth: CGFloat = 16    // width reserved for the copy button
    static let dismissButtonWidth: CGFloat = 16 // width reserved for the ✕ button
    static let copyGap: CGFloat = 8             // gap between text and the buttons
    static let buttonGap: CGFloat = 6           // gap between the two buttons

    /// Total horizontal room the copy + dismiss buttons (plus gaps) claim.
    static let copyReserve: CGFloat = copyGap + copyButtonWidth + buttonGap + dismissButtonWidth

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

    /// Fixed box used while an answer streams in (no per-token resizing).
    static let streamingBoxSize = CGSize(width: maxBoxWidth, height: 200)
    static var streamingPanelSize: CGSize {
        CGSize(width: streamingBoxSize.width + margin * 2,
               height: streamingBoxSize.height + margin * 2)
    }

    /// Extra height added below an assistant answer for the "Continue" button.
    static let continueFooterHeight: CGFloat = 34

    /// Panel sizes for an assistant answer (box + Continue footer).
    static func assistantPanelSize(for text: String) -> CGSize {
        let p = panelSize(for: text)
        return CGSize(width: p.width, height: p.height + continueFooterHeight)
    }
    static var assistantStreamingPanelSize: CGSize {
        CGSize(width: streamingPanelSize.width,
               height: streamingPanelSize.height + continueFooterHeight)
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
    /// Dictation listen (waveform pill) vs. assistant listen (black-hole pill).
    private var isDictationListening: Bool { isListening && !model.assistantListening }
    private var isAssistantListening: Bool { isListening && model.assistantListening }
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

    /// Coarse phase identity for driving the container animation — stable while
    /// the result text streams in.
    private var phaseRank: Int {
        switch model.phase {
        case .idle: return 0
        case .listening: return 1
        case .transcribing: return 2
        case .result: return 3
        case .saving: return 4
        case .saved: return 5
        case .tooShort: return 6
        case .error: return 7
        }
    }

    private var containerSize: CGSize {
        if model.streaming { return OverlayMetrics.streamingPanelSize }
        if case .result(let t) = model.phase {
            if model.isChat { return OverlayMetrics.assistantStreamingPanelSize }
            return model.assistantResult ? OverlayMetrics.assistantPanelSize(for: t)
                                          : OverlayMetrics.panelSize(for: t)
        }
        return OverlayMetrics.pillSize
    }

    var body: some View {
        ZStack {
            listeningPill
                .opacity(isDictationListening ? 1 : 0)
                .scaleEffect(isDictationListening ? 1 : 0.9)

            assistantListeningPill
                .opacity(isAssistantListening ? 1 : 0)
                .scaleEffect(isAssistantListening ? 1 : 0.9)

            transcribingPill(active: isTranscribing)
                .opacity(isTranscribing ? 1 : 0)
                .scaleEffect(isTranscribing ? 1 : 0.9)

            resultBox(resultText)
                .opacity(isResult ? 1 : 0)
                .scaleEffect(isResult ? 1 : 0.92)
        }
        .frame(width: containerSize.width, height: containerSize.height)
        // Animate on the coarse phase (idle/listen/transcribe/result), NOT the
        // per-token result text — otherwise every streamed token restarts the
        // spring and the text never settles/paints.
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: phaseRank)
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

    // MARK: - Assistant listening (black-hole orbit pill)

    private var assistantListeningPill: some View {
        // A round "ball" instead of the wide waveform capsule — the view draws
        // its own dark disc + orbiting mass, centered in the pill container.
        BlackHoleOrbitView(active: isAssistantListening)
            .frame(width: 40, height: 40)
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

    private let teal = Color(hue: 0.50, saturation: 0.68, brightness: 0.86)

    /// The result presentation: the answer box, plus a "Continue" button below
    /// it for assistant answers.
    private func resultBox(_ text: String) -> some View {
        VStack(spacing: 8) {
            answerBox(text)
            if model.assistantResult && !model.streaming {
                Button { model.onContinue?() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 10, weight: .bold))
                        Text("Continue")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(teal.opacity(0.32)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help("Keep this chat — your next assistant question continues it")
            }
        }
    }

    /// A single conversation turn: user messages sit right in a teal chip,
    /// assistant messages read as plain left-aligned text.
    private func bubble(_ role: String, _ text: String) -> some View {
        let isUser = role == "user"
        return Text(text)
            .font(.system(size: OverlayMetrics.fontSize - 1, design: .rounded))
            .foregroundStyle(.white.opacity(isUser ? 0.82 : 0.95))
            .multilineTextAlignment(.leading)
            .lineSpacing(1)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, isUser ? 10 : 0)
            .padding(.vertical, isUser ? 6 : 0)
            .background {
                if isUser {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(teal.opacity(0.20))
                }
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private func answerBox(_ text: String) -> some View {
        // Streaming or a multi-turn chat uses the fixed scrolling box; a fresh
        // single answer sizes to its text.
        let box = (model.streaming || model.isChat) ? OverlayMetrics.streamingBoxSize
                                                     : OverlayMetrics.boxSize(for: text)
        // Text column is the box minus its padding, the button, and the gap.
        let textWidth = box.width - OverlayMetrics.hInset * 2
            - OverlayMetrics.copyReserve
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: model.isChat ? 9 : 0) {
                    if model.isChat {
                        // Prior turns, then the new question, then this answer.
                        ForEach(model.priorTurns) { bubble($0.role, $0.text) }
                        if !model.currentQuestion.isEmpty {
                            bubble("user", model.currentQuestion)
                        }
                        bubble("assistant", text)
                    } else {
                        Text(text)
                            .font(.system(size: OverlayMetrics.fontSize, design: .rounded))
                            .foregroundStyle(.white.opacity(0.95))
                            .multilineTextAlignment(.leading)
                            .lineSpacing(1)
                            .textSelection(.enabled)
                            .frame(width: textWidth, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Anchor so we can keep the newest text in view while streaming.
                    Color.clear.frame(height: 1).id("streamEnd")
                }
                .padding(.leading, OverlayMetrics.hInset)
                // Reserve the button column on the right so text can't run under it.
                .padding(.trailing, OverlayMetrics.hInset + OverlayMetrics.copyReserve)
                .padding(.vertical, OverlayMetrics.vInset)
            }
            .onChange(of: text) { _, _ in
                if model.streaming { proxy.scrollTo("streamEnd", anchor: .bottom) }
            }
        }
            .frame(width: box.width, height: box.height, alignment: .topLeading)
            // Copy + dismiss buttons pinned to the top-right so they stay put as
            // text scrolls.
            .overlay(alignment: .topTrailing) {
                HStack(spacing: OverlayMetrics.buttonGap) {
                    CopyButton(text: text)
                    DismissButton { model.onDismiss?() }
                }
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

/// A small ✕ that dismisses the result box immediately.
private struct DismissButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: OverlayMetrics.dismissButtonWidth, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Dismiss")
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
