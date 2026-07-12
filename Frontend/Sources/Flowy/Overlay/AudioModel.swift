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

    // Visualiser shape dials.
    private let waveCeiling: Float = 0.82   // max bar height (fraction of pill)
    private let waveDensity = 0.95          // higher = more sine humps across the pill

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
        // Drives the wave amplitude — normal speech should reach a good height.
        targetGlow = min(1, rms * 9)
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
        // Ease overall loudness for smooth vertical growth/shrink.
        let gRate: Float = targetGlow > glow ? attack : decay
        glow = glow + (targetGlow - glow) * gRate

        let listening = phase == .listening
        // Soft-capped amplitude; grows with your voice, with a gentle idle floor.
        var amp = waveCeiling * tanhf(glow / waveCeiling)
        if listening { amp = max(amp, 0.14) }

        // Static sine wave (does NOT travel) — several humps across the pill,
        // growing vertically from the centre with volume.
        var newLevels = [Float](repeating: 0, count: bandCount)
        for i in 0..<bandCount {
            let wave = 0.5 + 0.5 * Float(sin(Double(i) * waveDensity))
            newLevels[i] = amp * (0.4 + 0.6 * wave)
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
