import CoreAudio
import Foundation

/// A running live (continuous) transcription — one at a time, made by the
/// resident model's `Recognizer.makeLiveSession`.
@MainActor
protocol LiveSession: AnyObject {
    /// Open the mic and start transcribing; false when it couldn't start.
    func start() -> Bool
    /// End capture and the realtime loop.
    func stop()
    /// Every sample captured so far this session (16 kHz mono).
    func snapshot() -> [Float]
}

/// What a live session gets from the app.
struct LiveContext {
    let model: String
    let mic: LiveMicInput
    /// The full running transcript so far (cleaned) and mic energy (0…~1).
    let onUpdate: @MainActor (_ transcript: String, _ energy: Float) -> Void
    /// The mic failed to open after `start` returned.
    let onFailure: (@MainActor () -> Void)?
    /// The stream's confirmed text and how many seconds of audio it covers —
    /// the stitched (tail-only) release decode starts from it.
    let onConfirmed: @MainActor (_ text: String, _ endSeconds: Double) -> Void
}

/// The microphone a live stream captures from: the shared capture unit and
/// the mic the user picked. Built on the main actor at session start, so
/// nothing on the stream's threads reads Settings.
struct LiveMicInput {
    var capture: MicCapture
    /// The chosen mic; nil = system default.
    var preferred: AudioDeviceID?
    /// The system default input, asked when the mic opens.
    var systemDefault: () -> AudioDeviceID?

    /// The device to open: the pick, else the system default.
    var device: AudioDeviceID? { preferred ?? systemDefault() }
}
