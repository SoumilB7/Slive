import SwiftUI

/// Observable state that drives the overlay. The audio thread pushes raw
/// levels in via `pushLevels`; a 60 fps timer eases the *displayed* values
/// toward those targets so the bars feel fluid and alive rather than jittery.
final class AudioModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case listening
        case saving
        case saved(seconds: Double)
        case tooShort
        case error(String)
    }

    @Published var phase: Phase = .idle
    @Published private(set) var levels: [Float]
    @Published private(set) var glow: Float = 0        // eased RMS, drives the halo
    @Published private(set) var elapsed: TimeInterval = 0

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

    init(bandCount: Int = 20) {
        self.bandCount = bandCount
        self.levels = [Float](repeating: 0, count: bandCount)
        self.targetLevels = [Float](repeating: 0, count: bandCount)
    }

    // MARK: - Lifecycle

    func beginListening() {
        phase = .listening
        elapsed = 0
        startDate = Date()
        startTimerIfNeeded()
    }

    /// Stop showing the pill: bars ease down and it fades out. No confirmation.
    func finishListening() {
        phase = .idle
        targetLevels = [Float](repeating: 0, count: bandCount)
        targetGlow = 0
    }

    func beginSaving() {
        phase = .saving
        targetLevels = [Float](repeating: 0, count: bandCount)
        targetGlow = 0
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
        // Drives the wave amplitude — stronger so normal audible speech reads high.
        targetGlow = min(1, rms * 18)
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
        // Grows with your voice and reaches high; soft-capped near the top.
        var amp = waveCeiling * tanhf(glow / 0.5)
        if listening { amp = max(amp, 0.14) }

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
            newLevels[i] = amp * (0.16 + 0.84 * arch) * wobble
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
