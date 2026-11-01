import CoreGraphics
import Foundation

/// One displayed conversation turn (role is "user" or "assistant").
struct ChatTurn: Identifiable, Equatable {
    let id = UUID()
    let role: String
    let text: String
}

/// What the overlay shows — one value in place of a phase plus seven
/// orthogonal flags (streaming, assistantListening, assistantResult,
/// liveDictating, priorTurns, currentQuestion, transcribingStuck). The panel
/// size and click-through are derived from it, so the SwiftUI content and
/// the NSPanel that hosts it can't disagree.
enum OverlayState: Equatable {
    /// Nothing on screen, or the pill easing out before it hides.
    case idle
    /// A session is capturing; the kind picks the pill's animation.
    case listening(ListenKind)
    /// Waiting on the decode or final pass (loading dots). `stuck`: the dots
    /// have spun long enough to offer a ✕ — the pill is click-through
    /// otherwise, so a stuck decode left an unclosable pill.
    case transcribing(stuck: Bool)
    /// The pill grown into a box (a dictation, notice, error or answer).
    case result(OverlayResult)

    /// Dictation listen (waveform pill) vs. assistant listen (black-hole
    /// pill) vs. continuous listen (pen-scribble pill).
    enum ListenKind: Equatable {
        case dictation
        case assistant
        case live
    }
}

/// The content of a result box.
struct OverlayResult: Equatable {
    var text: String
    /// A short line above a copy box saying why it wasn't typed (nil = none).
    var note: String?
    /// The result box is a failure message (drawn with an orange edge).
    var isError = false
    /// Set while showing an assistant answer (streaming or final) — drives
    /// the "Continue" footer. Nil for a plain box.
    var answer: Answer?

    struct Answer: Equatable {
        /// The answer is streaming in, so the box uses a fixed size and
        /// auto-scrolls instead of resizing on every token.
        var streaming: Bool
        /// Prior conversation turns shown above the current answer when
        /// continuing a chat (empty for a fresh, single question).
        var priorTurns: [ChatTurn] = []
        /// The current question being answered — a user bubble in chat mode.
        var question: String = ""
    }

    /// Whether to render the box as a multi-turn transcript.
    var isChat: Bool { !(answer?.priorTurns.isEmpty ?? true) }
    var isStreaming: Bool { answer?.streaming ?? false }
    /// The "Continue" footer: a finished assistant answer.
    var showsContinue: Bool { answer != nil && !isStreaming }

    /// The black box itself. Streaming or a multi-turn chat uses the fixed
    /// scrolling box; a fresh single answer sizes to its text.
    var boxSize: CGSize {
        (isStreaming || isChat) ? OverlayMetrics.streamingBoxSize
                                : OverlayMetrics.boxSize(for: text, note: note)
    }

    /// The container (and NSPanel) size: chat transcripts use the fixed
    /// scrolling box, a single answer sizes to its text plus the Continue
    /// footer, a plain box to its text and note.
    var panelSize: CGSize {
        if isStreaming { return OverlayMetrics.streamingPanelSize }
        if isChat { return OverlayMetrics.assistantStreamingPanelSize }
        return answer != nil ? OverlayMetrics.assistantPanelSize(for: text)
                             : OverlayMetrics.panelSize(for: text, note: note)
    }
}

extension OverlayState {
    var result: OverlayResult? {
        if case .result(let r) = self { return r }
        return nil
    }

    var listenKind: ListenKind? {
        if case .listening(let k) = self { return k }
        return nil
    }

    var isTranscribing: Bool {
        if case .transcribing = self { return true }
        return false
    }

    /// The container (and NSPanel) size: the pill unless a box is showing.
    var panelSize: CGSize { result?.panelSize ?? OverlayMetrics.pillSize }

    /// Click-through everywhere except while a result box is showing (its
    /// copy / ✕ / Continue buttons) and a stuck transcribing pill's ✕; the
    /// listening pills stay passive.
    var isInteractive: Bool {
        switch self {
        case .result: return true
        case .transcribing(let stuck): return stuck
        case .idle, .listening: return false
        }
    }

    /// Text shows bottom-centre even when the pill sits on the right.
    var showsText: Bool { result != nil }

    /// Coarse phase identity for driving the container animation — stable
    /// while the result text streams in (and across listening kinds).
    var rank: Int {
        switch self {
        case .idle: return 0
        case .listening: return 1
        case .transcribing: return 2
        case .result: return 3
        }
    }
}
