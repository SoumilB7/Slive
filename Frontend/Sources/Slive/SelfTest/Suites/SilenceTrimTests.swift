import AppKit
import CoreAudio
import CoreGraphics
import FluidAudio
import SliveObjC
import SliveReport

/// Silence trim (pre-decode)
@MainActor
enum SilenceTrimTests {
    static let suite = TestSuite(name: "Silence trim") { t in
        print("[Silence trim]")
        // Switching models never blocks dictation: the previous pick serves
        // until the new one is resident.
        let resident: Set<String> = ["tiny.en"]
        t.check(TranscriptionModel.pickServing(wanted: "large", fallback: "tiny.en",
                                             isResident: resident.contains) == "tiny.en",
              "new model still preparing → dictation keeps using the previous one")
        t.check(TranscriptionModel.pickServing(wanted: "tiny.en", fallback: "base.en",
                                             isResident: resident.contains) == "tiny.en",
              "the picked model wins once it's resident")
        t.check(TranscriptionModel.pickServing(wanted: "large", fallback: nil,
                                             isResident: resident.contains) == "large",
              "no previous model → wait for the pick (first launch)")
        // Engine routing: every Whisper id keeps meaning Whisper.
        t.check(["tiny.en", "large-v3-v20240930_626MB", "base.en", "my-finetune-2026"]
                .allSatisfy { SpeechEngine.of($0) == .whisper },
              "Whisper and custom model ids route to Whisper")
        t.check(SpeechEngine.of("parakeet-ultra") == .parakeet(.ultra)
                && SpeechEngine.of("parakeet-v2") == .parakeet(.v2),
              "Parakeet ids route to the Parakeet engine")
        t.check(ParakeetModel.allCases.allSatisfy { $0.rawValue.hasPrefix("parakeet-") },
              "every Parakeet id carries the parakeet- prefix")
        let basket = URL(fileURLWithPath: "/tmp/basket")
        t.check(ParakeetEngine.directory(for: .ultra, basket: basket).path == "/tmp/basket/parakeet/parakeet-ultra"
                && ParakeetEngine.directory(for: .v2, basket: basket).path == "/tmp/basket/parakeet/parakeet-tdt-0.6b-v2",
              "Parakeet models live in the basket under FluidAudio's folder names")
        t.check(WhisperModelChoice.parakeet.map(\.model) == ParakeetModel.allCases.map(\.rawValue)
                && Set(WhisperModelChoice.all.map(\.model)).isDisjoint(with: WhisperModelChoice.parakeet.map(\.model)),
              "picker: Parakeet entries separate from the Whisper list (dictation-only opt-in)")
        t.check(AppDelegate.postReleaseCaptureSeconds >= 0.1,
              "post-release capture keeps at least 0.1s")
        let rate = 16_000
        let quiet = [Float](repeating: 0.001, count: rate)          // 1s near-silence
        let voice = [Float](repeating: 0.1, count: rate / 2)        // 0.5s clear voice

        t.check(TranscriptionModel.trimSilence(quiet).isEmpty,
              "pure silence trims to empty (skip decode entirely)")

        let padded = quiet + voice + quiet
        let trimmed = TranscriptionModel.trimSilence(padded)
        let pads = TranscriptionModel.trimLeadPad + TranscriptionModel.trimTailPad
        t.check(!trimmed.isEmpty
                && trimmed.count >= voice.count
                && trimmed.count <= voice.count + pads + 320,
              "silence-padded voice trims to the voiced span + 150ms/300ms pads",
              "got \(trimmed.count) samples for \(voice.count) voiced")

        // The Sep 2026 bug: a sentence trailing off to ~0.005 RMS (well above
        // a quiet room's ~0.0005, below the old fixed 0.01 cut) lost its
        // last words before Whisper ever saw them.
        let room = [Float](repeating: 0.0005, count: rate)             // 1s quiet room
        let softTail = [Float](repeating: 0.005, count: rate * 2 / 5)  // 0.4s trailing-off words
        let trailing = room + voice + softTail + room
        let keptTail = TranscriptionModel.trimSilence(trailing)
        t.check(keptTail.count >= voice.count + softTail.count,
              "quiet trailing speech survives the trim",
              "got \(keptTail.count) samples, need ≥ \(voice.count + softTail.count)")
        t.check(TranscriptionModel.trimSilence(room + softTail + room).isEmpty,
              "soft noise with nothing above the speech gate is still silence")
        // Oct 8: a NOISY room (floor 0.003 → edge threshold clamps at 0.01)
        // with final words at 0.007 — the end edge must still keep them.
        let noisy = [Float](repeating: 0.003, count: rate)
        let softEnding = [Float](repeating: 0.007, count: rate * 2 / 5)
        let noisyClip = noisy + [Float](repeating: 0.05, count: rate) + softEnding + noisy
        let keptNoisy = TranscriptionModel.trimSilence(noisyClip)
        t.check(keptNoisy.endIndex >= noisy.count + rate + softEnding.count,
              "noisy room: soft final words survive the trim",
              "trim ended at \(keptNoisy.endIndex), soft words end at \(noisy.count + rate + softEnding.count)")
        t.check(keptNoisy.endIndex <= noisyClip.count - noisy.count / 2,
              "noisy room: plain room noise after the words is still trimmed")
        t.check(TranscriptionModel.edgeThreshold(
                frameRMS: [Float](repeating: 0.0005, count: 90) + [Float](repeating: 0.1, count: 10))
                == TranscriptionModel.trimEdgeFloor,
              "quiet room → edge threshold clamps to the 0.003 floor")
        t.check(TranscriptionModel.edgeThreshold(
                frameRMS: [Float](repeating: 0.004, count: 90) + [Float](repeating: 0.1, count: 10))
                == TranscriptionModel.trimSpeechGate,
              "noisy room → edge threshold never stricter than the old 0.01")
        // The voiced span itself must survive intact.
        t.check(trimmed.contains(0.1), "voiced samples survive the trim")

        let bare = TranscriptionModel.trimSilence(voice)
        t.check(bare.count == voice.count, "no-silence input passes through whole")

        t.check(TranscriptionModel.trimSilence([Float](repeating: 0, count: 100)).isEmpty,
              "sub-frame input trims to empty")

        // The Objective-C exception shim the mic path relies on: an
        // AVAudioEngine assertion must come back as a reason, not a SIGABRT.
        let raised = SliveCatchObjCException {
            NSException(name: .genericException, reason: "probe raise", userInfo: nil).raise()
        }
        t.check(raised?.contains("probe raise") == true,
              "ObjC raise is caught and reported", "got \(raised ?? "nil")")
        t.check(SliveCatchObjCException({}) == nil, "no raise → nil")

        // Microphone picker plumbing.
        t.check(DeviceRoutedAudioProcessor.effectiveDevice(requested: nil, preferred: 7) == 7,
              "continuous stream takes the chosen mic when the caller names none")
        t.check(DeviceRoutedAudioProcessor.effectiveDevice(requested: 3, preferred: 7) == 3,
              "an explicit device request beats the chosen mic")
        t.check(DeviceRoutedAudioProcessor.effectiveDevice(requested: nil, preferred: nil) == nil,
              "no pick → system default (nil)")
        t.check(InputDevices.resolve(uid: "") == nil, "empty UID resolves to system default")
        t.check(InputDevices.resolve(uid: "slive-self-test-no-such-device") == nil,
              "unknown UID falls back to system default")
        t.equal(InputDevices.Device.rateLabel(16_000), "16 kHz", "rate label whole kHz")
        t.equal(InputDevices.Device.rateLabel(44_100), "44.1 kHz", "rate label fractional kHz")
        t.equal(InputDevices.transportLabel(kAudioDeviceTransportTypeBluetooth), "Bluetooth", "transport label")
        t.check(InputDevices.transportLabel(0xDEAD_BEEF) == nil, "unknown transport omitted")

        // Capture backend choice: the engine (and its default-device
        // aggregate) only ever runs for echo cancellation.
        t.check(!AudioRecorder.usesEngine(echoCancellation: false),
              "AEC off → direct capture on the chosen mic only")
        t.check(AudioRecorder.usesEngine(echoCancellation: true),
              "AEC on → engine (system route)")
        t.check(MicCapture.canonicalFormat.sampleRate == 16_000
                && MicCapture.canonicalFormat.channelCount == 1,
              "direct capture delivers 16 kHz mono")
    }
}
