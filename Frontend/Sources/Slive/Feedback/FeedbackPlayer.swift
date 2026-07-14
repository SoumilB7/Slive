import AppKit
import AVFoundation

/// Plays a subtle, short synthesized audio cue when a hotkey action activates.
///
/// The cues are generated in code (no external audio assets) and cached as PCM
/// buffers so playback is instant. Both are deep, soft "dhum" thumps — a low
/// fundamental that glides down in pitch (the drop is what makes it feel
/// premium, not tinny) — kept quiet (~0.25 gain) since one plays right as
/// recording begins:
/// - `.dictate`: ~150→95 Hz, ~200 ms — a short deep "dhum".
/// - `.assist`: ~128→72 Hz, ~300 ms — a deeper, longer "dhummm".
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

        // Dictate: a deep, soft "dhum" — a low fundamental that drops in pitch
        // for a warm thump. No bright harmonics (those read as "tinny").
        dictateBuffer = Self.makeTone(
            format: format,
            sampleRate: sampleRate,
            startFrequency: 150,       // starts low…
            endFrequency: 95,          // …and glides down → "dhum"
            harmonic2Amplitude: 0.14,  // just a little body, kept warm
            duration: 0.200,           // ~200 ms
            attack: 0.006,             // 6 ms attack to avoid a start click
            decay: 10,                 // smooth decay
            gain: gain
        )

        // Assist: deeper and longer — a rounded "dhummm" with more resonance.
        assistBuffer = Self.makeTone(
            format: format,
            sampleRate: sampleRate,
            startFrequency: 128,
            endFrequency: 72,          // deeper drop
            harmonic2Amplitude: 0.16,
            duration: 0.300,           // ~300 ms
            attack: 0.008,             // 8 ms attack
            decay: 6.5,                // long, gentle tail
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
        case .stream:  buffer = dictateBuffer   // shares the dictation "dhum"
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
        case .dictate: name = NSSound.Name("Bottle")      // deeper than Tink
        case .assist:  name = NSSound.Name("Submarine")   // deep sonar-ish
        case .stream:  name = NSSound.Name("Bottle")
        }
        NSSound(named: name)?.play()
    }

    // MARK: - Tone synthesis

    /// Builds a mono PCM buffer containing a decaying sine whose pitch glides
    /// from `startFrequency` down to `endFrequency` (the drop is what gives a
    /// warm "dhum" thump), with an optional light 2nd harmonic for body, shaped
    /// by a short attack and an exponential decay.
    ///
    /// - Parameters:
    ///   - startFrequency / endFrequency: Pitch glides between these (Hz), giving
    ///     the downward "dhum". Set them equal for a steady tone.
    ///   - harmonic2Amplitude: Relative amplitude of the 2nd harmonic (0 = pure sine).
    ///   - duration: Total length in seconds.
    ///   - attack: Linear fade-in time in seconds (avoids a start-of-buffer click).
    ///   - decay: Exponential decay rate; larger = faster fade to silence.
    ///   - gain: Overall output scaling (kept low for a subtle cue).
    private static func makeTone(
        format: AVAudioFormat,
        sampleRate: Double,
        startFrequency: Double,
        endFrequency: Double,
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

        let attackFrames = max(1.0, attack * sampleRate)
        let ratio = endFrequency / startFrequency
        var phase = 0.0   // integrated so the gliding pitch stays continuous

        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let frac = t / duration
            // Exponential glide from start → end frequency.
            let freq = startFrequency * pow(ratio, frac)
            phase += 2.0 * Double.pi * freq / sampleRate

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
