import AVFoundation
import Foundation

/// How one recording captures. Built by the caller (from Settings), so the
/// capture code never reads Settings itself.
struct CaptureOptions: Equatable {
    /// The chosen mic's persisted UID; "" = system default. An unplugged pick
    /// falls back to the system default at start.
    var deviceUID: String = ""
    /// Run the system voice-processing chain (echo cancellation). Only the
    /// `VoiceProcessingSource` can; it follows the system default route.
    var echoCancellation: Bool = false

    static func fromSettings() -> CaptureOptions {
        CaptureOptions(deviceUID: Settings.shared.inputDeviceUID,
                       echoCancellation: Settings.shared.echoCancellation)
    }
}

/// Where recorded audio comes from. Main thread except the buffer callback.
///
/// Adding a source = one conforming type, chosen in `AudioRecorder.start`.
protocol AudioSource: AnyObject {
    /// Ready the source for one recording and return the format its buffers
    /// will have (nil = mic not usable). Called before the WAV opens.
    func prepare(_ options: CaptureOptions) -> AVAudioFormat?
    /// Start capture. `onAudioThreadBuffer` runs ON THE AUDIO THREAD for every
    /// buffer, which may be reused between callbacks — copy what you keep.
    /// False = couldn't start (already logged).
    func start(_ options: CaptureOptions,
               onAudioThreadBuffer: @escaping (AVAudioPCMBuffer) -> Void) -> Bool
    func stop()
    /// After the recording is finalized: pre-arm for the next hold, off the
    /// hot path.
    func rearm()
}

extension AudioSource {
    func rearm() {}
}

/// The default: `MicCapture`, a raw HAL output unit on exactly the
/// microphone chosen in Settings (or the system default). Opens that device
/// and nothing else — with a Bluetooth headset playing music, picking the
/// built-in mic leaves the headset in A2DP (why not AVAudioEngine: see
/// `MicCapture`). Buffers arrive already canonical (16 kHz mono). The unit
/// keeps itself initialized between holds.
final class AUHALSource: AudioSource {
    private let capture: MicCapture

    init(capture: MicCapture = .shared) {
        self.capture = capture
    }

    func prepare(_ options: CaptureOptions) -> AVAudioFormat? {
        MicCapture.canonicalFormat   // direct capture is canonical already
    }

    func start(_ options: CaptureOptions,
               onAudioThreadBuffer: @escaping (AVAudioPCMBuffer) -> Void) -> Bool {
        guard let device = InputDevices.resolve(uid: options.deviceUID) ?? InputDevices.defaultInputID() else {
            NSLog("Slive: no input device available")
            return false
        }
        do {
            try capture.start(device: device, onBuffer: onAudioThreadBuffer)
            return true
        } catch {
            NSLog("Slive: microphone open failed on device \(device): \(error.localizedDescription)")
            return false
        }
    }

    func stop() {
        capture.stop()
    }
}
