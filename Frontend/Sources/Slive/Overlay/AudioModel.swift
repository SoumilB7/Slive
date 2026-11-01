import SwiftUI

/// Observable state that drives the overlay: what it shows (`state`) and the
/// waveform bars. The audio thread pushes raw levels in via `pushLevels`; a
/// 60 fps timer eases the *displayed* values toward those targets so the bars
/// feel fluid and alive rather than jittery. Transitions come from
/// `OverlayPresenter`; the SwiftUI views only read.
final class AudioModel: ObservableObject {

    /// Invoked when the user taps the dismiss (✕) button on a result box.
    var onDismiss: (() -> Void)?
    /// Invoked when the user taps "Continue" under an assistant answer.
    var onContinue: (() -> Void)?

    @Published private(set) var state: OverlayState = .idle
    @Published private(set) var levels: [Float]

    let bandCount: Int
    private var meter: MeterEasing
    private var timer: Timer?

    init(bandCount: Int = 14) {
        self.bandCount = bandCount
        self.levels = [Float](repeating: 0, count: bandCount)
        self.meter = MeterEasing(bandCount: bandCount)
    }

    // MARK: - Lifecycle

    func beginListening(assistant: Bool = false) {
        state = .listening(assistant ? .assistant : .dictation)
        startTimerIfNeeded()
    }

    /// Start live-streaming dictation: a listening pill showing live energy.
    func beginLiveDictation() {
        state = .listening(.live)
        startTimerIfNeeded()
    }

    /// Drive the waveform from the live stream's mic energy (0…~1).
    func pushStreamEnergy(_ energy: Float) {
        meter.pushStreamEnergy(energy)
    }

    /// Stop showing the pill: bars ease down and it fades out. No confirmation.
    func finishListening() {
        state = .idle
        meter.silence()
    }

    /// Stopped recording; the audio is now on its way to the backend. Keep the
    /// pill on screen (a loading indicator is shown instead of the waveform).
    func beginTranscribing() {
        state = .transcribing(stuck: false)
        settleMeterNow()
    }

    /// From these phases on, the waveform is invisible (the listening pill is
    /// opacity-0; LoadingDots/result boxes don't read `levels`) — stop the 60Hz
    /// easer NOW instead of publishing a decaying, unseen waveform for ~0.4s.
    /// Mirrors the timer's own idle-stop reset so the next session starts clean.
    private func settleMeterNow() {
        meter.reset()
        stopTimer()
        levels = [Float](repeating: 0, count: bandCount)
    }

    /// Show the ✕ on the transcribing pill (no-op once it has moved on).
    func offerTranscribingDismiss() {
        guard state.isTranscribing else { return }
        state = .transcribing(stuck: true)
    }

    /// Backend returned text (dictation, or an error) — grow the pill into a box.
    func showResult(_ text: String, isError: Bool = false, note: String? = nil) {
        state = .result(OverlayResult(text: text, note: note, isError: isError))
        settleMeterNow()
    }

    /// Final assistant answer — like `showResult` but flags it so the Continue
    /// footer shows. Keeps the transcript (priorTurns/question) in place.
    func showAssistantResult(_ text: String) {
        let shown = state.result?.answer
        state = .result(OverlayResult(text: text, answer: .init(
            streaming: false, priorTurns: shown?.priorTurns ?? [], question: shown?.question ?? "")))
        settleMeterNow()
    }

    /// Start streaming an assistant answer into a fixed-size box. `priorTurns`
    /// are shown above the answer when continuing a chat.
    func beginStreaming(priorTurns: [ChatTurn] = [], question: String = "") {
        state = .result(OverlayResult(text: "", answer: .init(
            streaming: true, priorTurns: priorTurns, question: question)))
        settleMeterNow()
    }

    /// Update the streaming answer text (box stays fixed size, scrolls).
    func updateStreaming(_ text: String) {
        guard var r = state.result, r.isStreaming else { return }
        r.text = text
        state = .result(r)
    }

    func reset() {
        state = .idle
        meter.reset()
        stopTimer()
        levels = [Float](repeating: 0, count: bandCount)
    }

    // MARK: - Feed from audio thread (already dispatched to main)

    func pushLevels(_ bands: [Float], rms: Float) {
        meter.push(bands, rms: rms)
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
        let listening = state.listenKind != nil
        levels = meter.step(listening: listening)
        // Once idle and faded out, stop spinning the timer.
        if !listening && meter.isFadedOut {
            stopTimer()
            levels = [Float](repeating: 0, count: bandCount)
            meter.glow = 0
        }
    }
}

/// The waveform's easing math, one 60 fps step at a time: raw levels in,
/// displayed bar heights out.
struct MeterEasing {
    let bandCount: Int

    // Targets set from the audio callback; the displayed bars chase these.
    private var targetLevels: [Float]
    private var targetGlow: Float = 0
    /// Eased RMS driving the bar amplitude. Internal easing state — no view
    /// reads it directly (views read `levels`), so publishing it only fired
    /// dead objectWillChange invalidations 60x/sec.
    var glow: Float = 0
    private var noisePhase: Double = 0

    // Visualiser dial — the tallest the centre bar can reach.
    private let waveCeiling: Float = 0.92

    // Fast rise, gentle fall — the classic "lively meter" feel.
    private let attack: Float = 0.55
    private let decay: Float = 0.18

    init(bandCount: Int) {
        self.bandCount = bandCount
        self.targetLevels = [Float](repeating: 0, count: bandCount)
    }

    /// The bars have eased all the way down.
    var isFadedOut: Bool { glow < 0.01 }

    mutating func push(_ bands: [Float], rms: Float) {
        guard bands.count == bandCount else { return }
        targetLevels = bands
        // Perceptual loudness curve. Raw RMS is linear, so quiet speech barely
        // moves the bars while loud speech slams them. A gamma < 1 (here ≈ sqrt)
        // lifts the low end a lot and eases off up top, so the wave grows on a
        // smooth curve: clearly alive when soft, still tall when loud.
        let gain: Float = 34
        targetGlow = powf(min(1, rms * gain), 0.45)
    }

    /// The live stream's mic energy (0…~1).
    mutating func pushStreamEnergy(_ energy: Float) {
        targetGlow = powf(min(1, max(0, energy) * 4), 0.5)
    }

    /// Ease toward silence (the bars fall at their own pace).
    mutating func silence() {
        targetLevels = [Float](repeating: 0, count: bandCount)
        targetGlow = 0
    }

    /// Snap to silence now.
    mutating func reset() {
        silence()
        glow = 0
    }

    mutating func step(listening: Bool) -> [Float] {
        noisePhase += 0.05   // slow drift for the wobble (vertical, not sideways)

        // Ease overall loudness for smooth vertical growth/shrink.
        let gRate: Float = targetGlow > glow ? attack : decay
        glow = glow + (targetGlow - glow) * gRate

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
        return newLevels
    }
}
