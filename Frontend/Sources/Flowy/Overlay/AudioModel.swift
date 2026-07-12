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
    private var shimmerPhase: Double = 0

    // Fast rise, gentle fall — the classic "lively meter" feel.
    private let attack: Float = 0.55
    private let decay: Float = 0.18

    init(bandCount: Int = 28) {
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
        // Amplify RMS a touch so the halo reacts on normal speech.
        targetGlow = min(1, rms * 6)
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
        shimmerPhase += 0.08

        let listening = phase == .listening
        var newLevels = levels
        for i in 0..<bandCount {
            let target = targetLevels[i]
            let rate = target > newLevels[i] ? attack : decay
            var v = newLevels[i] + (target - newLevels[i]) * rate
            if listening {
                // A gentle travelling shimmer so silence still looks alive.
                let s = Float(sin(shimmerPhase + Double(i) * 0.5)) * 0.5 + 0.5
                let floorLevel = 0.05 + 0.05 * s
                v = max(v, floorLevel)
            }
            newLevels[i] = v
        }
        levels = newLevels

        let gRate: Float = targetGlow > glow ? attack : decay
        glow = glow + (targetGlow - glow) * gRate

        if listening, let start = startDate {
            elapsed = Date().timeIntervalSince(start)
        }

        // Once idle and fully settled, stop spinning the timer.
        if !listening && phase != .saving {
            let settled = levels.allSatisfy { $0 < 0.01 } && glow < 0.01
            if settled { stopTimer(); levels = [Float](repeating: 0, count: bandCount); glow = 0 }
        }
    }

    /// Keep the timer alive through the brief saving/saved states.
    func keepAnimating() { startTimerIfNeeded() }
}
