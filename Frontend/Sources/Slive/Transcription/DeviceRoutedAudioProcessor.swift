import AVFoundation
import CoreML
import Foundation
import SliveObjC
import WhisperKit

/// Gives WhisperKit's live stream (continuous mode) the microphone the user
/// chose in Settings — by capturing the audio ourselves.
///
/// `AudioStreamTranscriber` opens the mic through
/// `audioProcessor.startRecordingLive(callback:)` with no device parameter,
/// and WhisperKit's own AVAudioEngine has the macOS default-aggregate
/// problem (see `MicCapture`): it would open a Bluetooth headset's mic even
/// when the built-in mic was picked. So this wrapper conforms to
/// `AudioProcessing`, forwards everything to the pipeline's real
/// `AudioProcessor` — buffer, energy, purge all live there, and the rest of
/// `TranscriptionModel` keeps reading `pipe.audioProcessor` — but on
/// start/resume runs `MicCapture` on the chosen device and feeds the
/// canonical 16 kHz buffers into `AudioProcessor.processBuffer`, exactly as
/// WhisperKit's own tap would. WhisperKit's engine never starts.
///
/// If the pipeline's processor isn't the concrete `AudioProcessor` (no
/// `processBuffer`), it falls back to WhisperKit's engine — through the
/// ObjC shim, so a raise there is a stream error, not a SIGABRT.
final class DeviceRoutedAudioProcessor: AudioProcessing {
    private var base: any AudioProcessing
    private let concrete: AudioProcessor?
    /// The mic to use when the caller doesn't name one; nil = system default.
    let preferredDevice: DeviceID?
    private let capture = MicCapture.shared

    init(base: any AudioProcessing, preferredDevice: DeviceID?) {
        self.base = base
        self.concrete = base as? AudioProcessor
        self.preferredDevice = preferredDevice
    }

    /// An explicit request always wins; otherwise the user's pick.
    static func effectiveDevice(requested: DeviceID?, preferred: DeviceID?) -> DeviceID? {
        requested ?? preferred
    }

    struct EngineRaised: LocalizedError {
        let reason: String
        var errorDescription: String? { "microphone engine refused: \(reason)" }
    }

    // MARK: Forwarded statics

    static func loadAudio(fromPath audioFilePath: String, startTime: Double?, endTime: Double?,
                          maxReadFrameSize: AVAudioFrameCount?) throws -> AVAudioPCMBuffer {
        try AudioProcessor.loadAudio(fromPath: audioFilePath, startTime: startTime,
                                     endTime: endTime, maxReadFrameSize: maxReadFrameSize)
    }

    static func loadAudio(at audioPaths: [String]) async -> [Result<[Float], Swift.Error>] {
        await AudioProcessor.loadAudio(at: audioPaths)
    }

    static func padOrTrimAudio(fromArray audioArray: [Float], startAt startIndex: Int,
                               toLength frameLength: Int, saveSegment: Bool) -> MLMultiArray? {
        AudioProcessor.padOrTrimAudio(fromArray: audioArray, startAt: startIndex,
                                      toLength: frameLength, saveSegment: saveSegment)
    }

    // MARK: Forwarded state

    var audioSamples: ContiguousArray<Float> { base.audioSamples }
    func purgeAudioSamples(keepingLast keep: Int) { base.purgeAudioSamples(keepingLast: keep) }
    var relativeEnergy: [Float] { base.relativeEnergy }
    var relativeEnergyWindow: Int {
        get { base.relativeEnergyWindow }
        set { base.relativeEnergyWindow = newValue }
    }

    // MARK: Recording — the routed calls

    func startRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        try open(inputDeviceID: inputDeviceID, callback: callback, resume: false)
    }

    func resumeRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        try open(inputDeviceID: inputDeviceID, callback: callback, resume: true)
    }

    func pauseRecording() {
        if capture.isRunning { capture.stop() } else { base.pauseRecording() }
    }

    func stopRecording() {
        capture.stop()
        base.stopRecording()   // no-op for the engine it never started
    }

    private func open(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?, resume: Bool) throws {
        let picked = Self.effectiveDevice(requested: inputDeviceID, preferred: preferredDevice)
        if let concrete, let device = picked ?? InputDevices.defaultInputID() {
            try capture.start(device: device) { buffer in
                guard let channel = buffer.floatChannelData else { return }
                let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
                concrete.processBuffer(samples)
                callback?(samples)
            }
            Log.app("continuous mic → device \(device) (direct capture)")
            return
        }
        // Fallback: WhisperKit's own engine, guarded.
        try guarded {
            if resume {
                try base.resumeRecordingLive(inputDeviceID: picked, callback: callback)
            } else {
                try base.startRecordingLive(inputDeviceID: picked, callback: callback)
            }
        }
    }

    /// Run an engine call so that an Objective-C raise surfaces as a Swift
    /// error (the stream logs "stream ERROR" and the app lives).
    private func guarded(_ body: () throws -> Void) throws {
        var thrown: Error?
        let raised = SliveCatchObjCException {
            do { try body() } catch { thrown = error }
        }
        if let raised { throw EngineRaised(reason: raised) }
        if let thrown { throw thrown }
    }
}
