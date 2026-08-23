import AVFoundation
import CoreML
import Foundation
import SliveObjC
import WhisperKit

/// Routes WhisperKit's live microphone (continuous mode) to the microphone
/// the user chose in Settings.
///
/// `AudioStreamTranscriber` opens the mic itself via
/// `audioProcessor.startRecordingLive(callback:)` — no device parameter
/// reaches it, so the stream would always use the system default. This thin
/// `AudioProcessing` wrapper sits between the transcriber and the pipeline's
/// real `AudioProcessor`: every call forwards untouched, except
/// start/resume, which supply the chosen device when the caller gave none.
/// The buffer, energy, and purge state all live in the wrapped processor, so
/// the rest of `TranscriptionModel` keeps reading `pipe.audioProcessor`.
///
/// Also the only place a raise inside WhisperKit's engine setup (it installs
/// its tap with an explicit format — the same assertion that crashed the
/// one-shot path) can be turned into a thrown error instead of a SIGABRT.
final class DeviceRoutedAudioProcessor: AudioProcessing {
    private var base: any AudioProcessing
    /// The mic to use when the caller doesn't name one; nil = system default.
    let preferredDevice: DeviceID?

    init(base: any AudioProcessing, preferredDevice: DeviceID?) {
        self.base = base
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
        let device = Self.effectiveDevice(requested: inputDeviceID, preferred: preferredDevice)
        try guarded { try base.startRecordingLive(inputDeviceID: device, callback: callback) }
    }

    func resumeRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        let device = Self.effectiveDevice(requested: inputDeviceID, preferred: preferredDevice)
        try guarded { try base.resumeRecordingLive(inputDeviceID: device, callback: callback) }
    }

    func pauseRecording() { base.pauseRecording() }
    func stopRecording() { base.stopRecording() }

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
