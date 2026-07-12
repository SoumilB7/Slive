import SwiftUI

/// Observable state that drives the overlay. The audio thread pushes raw
/// levels in via `pushLevels`; a 60 fps timer eases the *displayed* values
/// toward those targets so the bars feel fluid and alive rather than jittery.
final class AudioModel: ObservableObject {

    /// One displayed conversation turn (role is "user" or "assistant").
    struct ChatTurn: Identifiable, Equatable {
        let id = UUID()
        let role: String
        let text: String
    }

    enum Phase: Equatable {
        case idle
        case listening
        case saving
        case saved(seconds: Double)
        case tooShort
        case error(String)
        /// Waiting on the backend to return the transcript.
        case transcribing
        /// Backend returned text — grown into a box and displayed briefly.
        case result(text: String)
    }

    /// Invoked when the user taps the dismiss (✕) button on a result box.
    var onDismiss: (() -> Void)?
    /// Invoked when the user taps "Continue" under an assistant answer.
    var onContinue: (() -> Void)?

    @Published var phase: Phase = .idle
    @Published private(set) var levels: [Float]
    @Published private(set) var glow: Float = 0        // eased RMS, drives the halo
    @Published private(set) var elapsed: TimeInterval = 0
    /// True while an assistant answer is streaming in, so the box uses a fixed
    /// size and auto-scrolls instead of resizing on every token.
    @Published private(set) var streaming = false
    /// True while the CURRENT recording is for the assistant (fn+ctrl) rather
    /// than plain dictation — drives which listening animation the pill shows.
    @Published private(set) var assistantListening = false
    /// True while showing an assistant answer (streaming or final) — drives the
    /// "Continue" footer button.
    @Published private(set) var assistantResult = false
    /// Prior conversation turns shown above the current answer when continuing a
    /// chat (empty for a fresh, single question).
    @Published private(set) var priorTurns: [ChatTurn] = []
    /// The current question being answered — shown as a user bubble in chat mode.
    @Published private(set) var currentQuestion: String = ""
    /// True while live-streaming dictation is running (a distinct listening pill
    /// with a caption of the words about to land).
    @Published private(set) var liveDictating = false
    /// The still-forming tail shown as a caption during live dictation.
    @Published private(set) var liveTail = ""

    /// Whether to render the box as a multi-turn transcript.
    var isChat: Bool { !priorTurns.isEmpty }

    let bandCount: Int

    // Targets set from the audio callback; `levels`/`glow` chase these.
    private var targetLevels: [Float]
    private var targetGlow: Float = 0

    private var timer: Timer?
    private var startDate: Date?
    private var noisePhase: Double = 0

    // Visualiser dial — the tallest the centre bar can reach.
    private let waveCeiling: Float = 0.92

    // Fast rise, gentle fall — the classic "lively meter" feel.
    private let attack: Float = 0.55
    private let decay: Float = 0.18

    init(bandCount: Int = 14) {
        self.bandCount = bandCount
        self.levels = [Float](repeating: 0, count: bandCount)
        self.targetLevels = [Float](repeating: 0, count: bandCount)
    }

    // MARK: - Lifecycle

    func beginListening(assistant: Bool = false) {
        streaming = false
        assistantListening = assistant
        liveDictating = false
        liveTail = ""
        phase = .listening
        elapsed = 0
        startDate = Date()
        startTimerIfNeeded()
    }

    /// Start live-streaming dictation: a listening pill with a caption showing
    /// the words that are about to land in your text field.
    func beginLiveDictation() {
        streaming = false
        assistantListening = false
        liveDictating = true
        liveTail = ""
        phase = .listening
        elapsed = 0
        startDate = Date()
        startTimerIfNeeded()
    }

    /// Update the caption of not-yet-committed words during live dictation.
    func updateLiveTail(_ text: String) {
        liveTail = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drive the waveform from the live stream's mic energy (0…~1).
    func pushStreamEnergy(_ energy: Float) {
        targetGlow = powf(min(1, max(0, energy) * 4), 0.5)
    }

    /// Stop showing the pill: bars ease down and it fades out. No confirmation.
    func finishListening() {
        phase = .idle
        liveDictating = false
        liveTail = ""
        targetLevels = [Float](repeating: 0, count: bandCount)
        targetGlow = 0
    }

    func beginSaving() {
        phase = .saving
        targetLevels = [Float](repeating: 0, count: bandCount)
        targetGlow = 0
    }

    /// Stopped recording; the audio is now on its way to the backend. Keep the
    /// pill on screen (a loading indicator is shown instead of the waveform).
    func beginTranscribing() {
        phase = .transcribing
        targetLevels = [Float](repeating: 0, count: bandCount)
        targetGlow = 0
    }

    /// Backend returned text (dictation, or an error) — grow the pill into a box.
    func showResult(_ text: String) {
        streaming = false
        assistantResult = false
        priorTurns = []
        currentQuestion = ""
        phase = .result(text: text)
        targetLevels = [Float](repeating: 0, count: bandCount)
        targetGlow = 0
    }

    /// Final assistant answer — like `showResult` but flags it so the Continue
    /// footer shows. Keeps the transcript (priorTurns/currentQuestion) in place.
    func showAssistantResult(_ text: String) {
        streaming = false
        assistantResult = true
        phase = .result(text: text)
        targetLevels = [Float](repeating: 0, count: bandCount)
        targetGlow = 0
    }

    /// Start streaming an assistant answer into a fixed-size box. `priorTurns`
    /// are shown above the answer when continuing a chat.
    func beginStreaming(priorTurns: [ChatTurn] = [], question: String = "") {
        streaming = true
        assistantResult = true
        self.priorTurns = priorTurns
        self.currentQuestion = question
        phase = .result(text: "")
        targetLevels = [Float](repeating: 0, count: bandCount)
        targetGlow = 0
    }

    /// Update the streaming answer text (box stays fixed size, scrolls).
    func updateStreaming(_ text: String) {
        guard streaming else { return }
        phase = .result(text: text)
    }

    func finishSaved(seconds: Double) {
        phase = .saved(seconds: seconds)
    }

    func fail(_ message: String) {
        phase = .error(message)
    }

    func tooShort() {
        phase = .tooShort
    }

    func reset() {
        phase = .idle
        streaming = false
        assistantListening = false
        assistantResult = false
        liveDictating = false
        liveTail = ""
        priorTurns = []
        currentQuestion = ""
        startDate = nil
        targetLevels = [Float](repeating: 0, count: bandCount)
        targetGlow = 0
        stopTimer()
        levels = [Float](repeating: 0, count: bandCount)
        glow = 0
        elapsed = 0
    }

    // MARK: - Feed from audio thread (already dispatched to main)

    func pushLevels(_ bands: [Float], rms: Float) {
        guard bands.count == bandCount else { return }
        targetLevels = bands
        // Perceptual loudness curve. Raw RMS is linear, so quiet speech barely
        // moves the bars while loud speech slams them. A gamma < 1 (here ≈ sqrt)
        // lifts the low end a lot and eases off up top, so the wave grows on a
        // smooth curve: clearly alive when soft, still tall when loud.
        let gain: Float = 34
        targetGlow = powf(min(1, rms * gain), 0.45)
    }

    // MARK: - 60 fps easing

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        noisePhase += 0.05   // slow drift for the wobble (vertical, not sideways)

        // Ease overall loudness for smooth vertical growth/shrink.
        let gRate: Float = targetGlow > glow ? attack : decay
        glow = glow + (targetGlow - glow) * gRate

        let listening = phase == .listening
        // `glow` is already loudness-shaped, so map it near-linearly here — a
        // second compression (the old tanh) would flatten the curve back out.
        var amp = waveCeiling * glow
        if listening { amp = max(amp, 0.24) }

        // A SINGLE hump — tall in the centre, tapering to both edges — that
        // grows vertically with volume. Static (does not travel), but each bar
        // gets a subtle drifting wobble so it feels organic, not mechanical.
        var newLevels = [Float](repeating: 0, count: bandCount)
        let n = bandCount
        for i in 0..<n {
            let p = n > 1 ? Double(i) / Double(n - 1) : 0.5
            let arch = Float(sin(.pi * p))          // 0 at edges → 1 at centre
            // Two incommensurate sines per bar → smooth, random-looking jitter.
            let noise = sin(noisePhase * 1.7 + Double(i) * 1.3)
                      + sin(noisePhase * 1.1 + Double(i) * 2.9)   // [-2, 2]
            let wobble = 1 + 0.11 * Float(noise)                  // ≈ ±22%
            newLevels[i] = amp * (0.38 + 0.62 * arch) * wobble
        }
        levels = newLevels

        if listening, let start = startDate {
            elapsed = Date().timeIntervalSince(start)
        }

        // Once idle and faded out, stop spinning the timer.
        if !listening && phase != .saving && glow < 0.01 {
            stopTimer()
            levels = [Float](repeating: 0, count: bandCount)
            glow = 0
        }
    }

    /// Keep the timer alive through the brief saving/saved states.
    func keepAnimating() { startTimerIfNeeded() }
}
