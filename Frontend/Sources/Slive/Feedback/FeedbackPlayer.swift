import AppKit
import AVFoundation

/// The sound an action makes as it goes live (`ActionSpec.cue`). Both are
/// deep, soft "dhum" thumps — a low fundamental that glides down in pitch
/// (the drop is what makes it feel premium, not tinny):
/// - `.dhum` (dictation, live typing): ~150→95 Hz, ~200 ms — a short deep "dhum".
/// - `.deepDhum` (assistant): ~128→72 Hz, ~300 ms — a deeper, longer "dhummm".
enum ActivationCue: CaseIterable {
    case dhum
    case deepDhum

    /// The synthesized tone (see `FeedbackPlayer.makeTone`).
    var tone: Tone {
        switch self {
        // A deep, soft "dhum" — a low fundamental that drops in pitch for a
        // warm thump. No bright harmonics (those read as "tinny").
        case .dhum:
            return Tone(startFrequency: 150,       // starts low…
                        endFrequency: 95,          // …and glides down → "dhum"
                        harmonic2Amplitude: 0.14,  // just a little body, kept warm
                        duration: 0.200,           // ~200 ms
                        attack: 0.006,             // 6 ms attack to avoid a start click
                        decay: 10)                 // smooth decay
        // Deeper and longer — a rounded "dhummm" with more resonance.
        case .deepDhum:
            return Tone(startFrequency: 128,
                        endFrequency: 72,          // deeper drop
                        harmonic2Amplitude: 0.16,
                        duration: 0.300,           // ~300 ms
                        attack: 0.008,             // 8 ms attack
                        decay: 6.5)                // long, gentle tail
        }
    }

    /// The system sound played when the engine can't.
    var fallbackSound: NSSound.Name {
        switch self {
        case .dhum:     return NSSound.Name("Bottle")      // deeper than Tink
        case .deepDhum: return NSSound.Name("Submarine")   // deep sonar-ish
        }
    }

    /// Parameters for `FeedbackPlayer.makeTone`.
    struct Tone {
        let startFrequency: Double
        let endFrequency: Double
        let harmonic2Amplitude: Double
        let duration: Double
        let attack: Double
        let decay: Double
    }
}

/// Plays a subtle, short synthesized audio cue when a hotkey action activates.
///
/// The cues (`ActivationCue`) are generated in code (no external audio
/// assets) and cached as PCM buffers so playback is instant, kept quiet
/// (~0.25 gain) since one plays right as recording begins.
///
/// Playback routes through a single persistent `AVAudioEngine` + player node.
/// If starting the engine fails for a cue, that cue falls back to a system
/// `NSSound` so the app never crashes and the user always gets some cue — the
/// next cue tries the engine again.
final class FeedbackPlayer {
    static let shared = FeedbackPlayer()

    // MARK: - Audio format

    private let sampleRate: Double = 44_100
    private let gain: Float = 0.25

    // MARK: - Engine (built once, started on demand, reused)

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat

    /// Every engine call runs here, never on main: `engine.start()` blocks
    /// while the output route settles — a Bluetooth HFP↔A2DP flip takes
    /// hundreds of ms — and on main that stalled the pill and the hotkey tap
    /// right at key-down. Serial, since AVAudioEngine isn't thread-safe.
    private let queue = DispatchQueue(label: "com.slive.app.feedback", qos: .userInitiated)

    /// Set when the graph must be re-wired + re-prepared before the next cue:
    /// after an `AVAudioEngineConfigurationChange` (output device switched,
    /// e.g. a Bluetooth HFP↔A2DP flip) or a failed start. Never latches the
    /// engine off — a transient failure must not cost every later cue the
    /// fallback sound until relaunch. `queue` only.
    private var needsRebuild = false
    private var configObserver: NSObjectProtocol?

    // MARK: - Cached tone buffers

    /// One buffer per cue, built once at init.
    private var buffers: [ActivationCue: AVAudioPCMBuffer] = [:]

    private init() {
        // Mono, Float32, 44.1 kHz.
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        for cue in ActivationCue.allCases {
            buffers[cue] = Self.makeTone(cue.tone, format: format, sampleRate: sampleRate, gain: gain)
        }

        setupEngine()

        // The engine stops itself on a route change; rebuild lazily on the
        // next cue rather than spinning audio hardware up here.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.needsRebuild = true }
        }
    }

    deinit {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - Public API

    /// Plays a subtle activation cue for the given action. Non-blocking; safe to
    /// call from any thread. Falls back to a system sound if synthesis playback
    /// is unavailable.
    func playActivation(for action: HotkeyAction) {
        let requested = CFAbsoluteTimeGetCurrent()
        queue.async { [self] in
            // A cue stuck behind a slow engine start is no longer "you're
            // live" — drop it rather than thump mid-sentence.
            guard CFAbsoluteTimeGetCurrent() - requested < 0.5 else { return }
            play(for: action)
        }
    }

    private func play(for action: HotkeyAction) {
        let cue = action.spec.cue
        guard let buffer = buffers[cue] else {
            playFallback(cue)
            return
        }

        if needsRebuild {
            needsRebuild = false
            rebuildGraph()
        }
        // Not running: never started yet, idled by auto-shutdown, or stopped
        // by a route change. Start on demand; a failure costs THIS cue only.
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                NSLog("Slive: feedback engine start failed — fallback cue: \(error)")
                needsRebuild = true
                playFallback(cue)
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
        // Let the engine idle the audio hardware between cues. Without this the
        // engine ran 24/7 — a real-time IO thread pulling silence (~86 render
        // callbacks/sec) and a coreaudiod power assertion for the whole app
        // lifetime, to play a 200ms thump a few dozen times a day. Auto-shutdown
        // stops the graph when idle and restarts transparently on demand —
        // unlike a manual stop-after-linger, there's no completion-handler
        // threading to race (they fire off-main and AVAudioEngine isn't
        // thread-safe).
        engine.isAutoShutdownEnabled = true
        engine.prepare()
        // Don't start here: playActivation's `!engine.isRunning` path starts it
        // on first use, so launch never spins up audio hardware at all.
    }

    /// Re-wire the player after a route change or failed start: the old
    /// connection may hold stale render resources for the previous device.
    /// Cheap while stopped, and still doesn't start the engine.
    private func rebuildGraph() {
        player.stop()
        engine.stop()
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }

    // MARK: - Fallback

    private func playFallback(_ cue: ActivationCue) {
        let name = cue.fallbackSound
        DispatchQueue.main.async { NSSound(named: name)?.play() }
    }

    // MARK: - Tone synthesis

    /// Builds a mono PCM buffer containing a decaying sine whose pitch glides
    /// from `startFrequency` down to `endFrequency` (the drop is what gives a
    /// warm "dhum" thump), with an optional light 2nd harmonic for body, shaped
    /// by a short attack and an exponential decay.
    ///
    /// - Parameters (`tone`'s fields, then the output's):
    ///   - startFrequency / endFrequency: Pitch glides between these (Hz), giving
    ///     the downward "dhum". Set them equal for a steady tone.
    ///   - harmonic2Amplitude: Relative amplitude of the 2nd harmonic (0 = pure sine).
    ///   - duration: Total length in seconds.
    ///   - attack: Linear fade-in time in seconds (avoids a start-of-buffer click).
    ///   - decay: Exponential decay rate; larger = faster fade to silence.
    ///   - gain: Overall output scaling (kept low for a subtle cue).
    static func makeTone(
        _ tone: ActivationCue.Tone,
        format: AVAudioFormat,
        sampleRate: Double,
        gain: Float
    ) -> AVAudioPCMBuffer? {
        let startFrequency = tone.startFrequency
        let endFrequency = tone.endFrequency
        let harmonic2Amplitude = tone.harmonic2Amplitude
        let duration = tone.duration
        let attack = tone.attack
        let decay = tone.decay
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
