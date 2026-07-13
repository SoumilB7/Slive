import AppKit
import AVFoundation

/// Plays a subtle, short synthesized audio cue when a hotkey action activates.
///
/// The cues are generated in code (no external audio assets) and cached as PCM
/// buffers so playback is instant. One of these plays exactly when microphone
/// recording begins, so both cues are deliberately quiet (~0.25 gain) and short:
/// - `.dictate`: a soft, bright "tick" — 1.6 kHz sine (+ light 2nd harmonic),
///   ~70 ms with a fast exponential decay.
/// - `.assist`: a deeper, rounder "tung" — 220 Hz sine (+ light 2nd harmonic),
///   ~190 ms with a gentle exponential decay so it reads as a soft mallet.
///
/// Playback routes through a single persistent `AVAudioEngine` + player node.
/// If engine setup or playback ever fails, we fall back to a system `NSSound`
/// so the app never crashes and the user always gets some cue.
final class FeedbackPlayer {
    static let shared = FeedbackPlayer()

    // MARK: - Audio format

    private let sampleRate: Double = 44_100
    private let gain: Float = 0.25

    // MARK: - Engine (built lazily, started once, reused)

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat

    /// Whether the engine is running and ready to schedule buffers.
    private var engineReady = false

    // MARK: - Cached tone buffers

    private var dictateBuffer: AVAudioPCMBuffer?
    private var assistBuffer: AVAudioPCMBuffer?

    private init() {
        // Mono, Float32, 44.1 kHz.
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        // Dictate: bright, high, very short tick.
        dictateBuffer = Self.makeTone(
            format: format,
            sampleRate: sampleRate,
            frequency: 1_600,          // ~1.6 kHz, bright
            harmonic2Amplitude: 0.20,  // faint 2nd harmonic for a touch of "click"
            duration: 0.070,           // ~70 ms
            attack: 0.004,             // 4 ms attack to avoid a start click
            decay: 45,                 // fast exponential decay
            gain: gain
        )

        // Assist: deeper, rounder, soft-mallet thunk.
        assistBuffer = Self.makeTone(
            format: format,
            sampleRate: sampleRate,
            frequency: 220,            // ~220 Hz, deep and round
            harmonic2Amplitude: 0.25,  // gentle body
            duration: 0.190,           // ~190 ms
            attack: 0.006,             // 6 ms attack
            decay: 14,                 // gentle decay -> mallet/gong feel
            gain: gain
        )

        setupEngine()
    }

    // MARK: - Public API

    /// Plays a subtle activation cue for the given action. Non-blocking; safe to
    /// call on the main thread. Falls back to a system sound if synthesis playback
    /// is unavailable.
    func playActivation(for action: HotkeyAction) {
        let buffer: AVAudioPCMBuffer?
        switch action {
        case .dictate: buffer = dictateBuffer
        case .assist:  buffer = assistBuffer
        }

        guard engineReady, let buffer else {
            playFallback(for: action)
            return
        }

        // The engine can stop after audio-route changes; restart if needed.
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                engineReady = false
                playFallback(for: action)
                return
            }
        }

        if !player.isPlaying {
            player.play()
        }

        // Scheduling returns immediately; playback happens on the audio thread.
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }

    // MARK: - Engine setup

    private func setupEngine() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
            player.play()
            engineReady = true
        } catch {
            engineReady = false
        }
    }

    // MARK: - Fallback

    private func playFallback(for action: HotkeyAction) {
        let name: NSSound.Name
        switch action {
        case .dictate: name = NSSound.Name("Tink")
        case .assist:  name = NSSound.Name("Bottle")
        }
        NSSound(named: name)?.play()
    }

    // MARK: - Tone synthesis

    /// Builds a mono PCM buffer containing a decaying sine (with an optional light
    /// 2nd harmonic), shaped by a short linear attack and an exponential decay.
    ///
    /// - Parameters:
    ///   - frequency: Fundamental frequency in Hz.
    ///   - harmonic2Amplitude: Relative amplitude of the 2nd harmonic (0 = pure sine).
    ///   - duration: Total length in seconds.
    ///   - attack: Linear fade-in time in seconds (avoids a start-of-buffer click).
    ///   - decay: Exponential decay rate; larger = faster fade to silence.
    ///   - gain: Overall output scaling (kept low for a subtle cue).
    private static func makeTone(
        format: AVAudioFormat,
        sampleRate: Double,
        frequency: Double,
        harmonic2Amplitude: Double,
        duration: Double,
        attack: Double,
        decay: Double,
        gain: Float
    ) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0]
        else { return nil }

        buffer.frameLength = frameCount

        let angularStep = 2.0 * Double.pi * frequency / sampleRate
        let attackFrames = max(1.0, attack * sampleRate)

        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let phase = angularStep * Double(i)

            // Fundamental + light 2nd harmonic, normalized so the peak stays ~1.
            let raw = (sin(phase) + harmonic2Amplitude * sin(2.0 * phase))
                / (1.0 + harmonic2Amplitude)

            // Short linear attack, then exponential decay.
            let attackEnv = min(1.0, Double(i) / attackFrames)
            let decayEnv = exp(-decay * t)
            let envelope = attackEnv * decayEnv

            channel[i] = Float(raw * envelope) * gain
        }

        return buffer
    }
}
