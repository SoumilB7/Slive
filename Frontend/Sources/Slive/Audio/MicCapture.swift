import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Input-only microphone capture on ONE explicit device, driving the HAL
/// output unit directly — no AVAudioEngine.
///
/// Why not the engine: on macOS `AVAudioEngine.inputNode` is one shared
/// AUHAL bound to the DEFAULT devices. When the default input and output
/// are different devices (a Bluetooth headset is two: `…:input` at 16 kHz
/// HFP and `…:output` at 44.1 kHz A2DP) it builds a `CADefaultDeviceAggregate`
/// around both — so merely starting the engine opens the headset's mic and
/// flips it from music quality to headset quality. Pointing the engine's
/// unit at another device fights it: the node keeps its cached format,
/// `Initialize` fails ("formats don't match"), and the engine falls back to
/// the default aggregate anyway (Aug 28, 2026 log). A raw AUHAL with output
/// disabled and `kAudioOutputUnitProperty_CurrentDevice` set touches exactly
/// the device asked for and nothing else.
///
/// Delivers buffers ALREADY canonical — 16 kHz mono Float32 — on the audio
/// thread (`onBuffer`); the buffer is reused between callbacks, so consumers
/// copy what they keep. The unit stays initialized between holds and only
/// stops IO, so a re-start is a few ms and the mic indicator goes off.
final class MicCapture {
    /// One unit for the app: one-shot and continuous never capture at the
    /// same time, and sharing keeps the device warm across modes.
    static let shared = MicCapture()

    static let canonicalFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    struct CaptureError: LocalizedError {
        let stage: String
        let status: OSStatus
        var errorDescription: String? { "\(stage) failed (\(status))" }
    }

    /// The device-side input format a unit was built against, read straight
    /// from the device (not the AUHAL) so build-time and start-time readings
    /// are the same measurement.
    struct HardwareShape: Equatable {
        let sampleRate: Double
        let channels: UInt32
    }

    private var unit: AudioUnit?
    private var boundDevice: AudioDeviceID = 0
    private var builtShape: HardwareShape?
    private(set) var deviceFormat: AVAudioFormat?
    private var renderBuffer: AVAudioPCMBuffer?
    private var converter: AVAudioConverter?
    private var outBuffer: AVAudioPCMBuffer?
    private(set) var isRunning = false
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var loggedRenderError = false

    deinit { dispose() }

    /// Start IO on `device`, rebuilding the unit if it was built for another
    /// device (or never), or the device's format changed since. Throws with
    /// the failing stage + OSStatus.
    func start(device: AudioDeviceID, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        if isRunning { return }
        self.onBuffer = onBuffer
        // A kept unit only knows the format it was built with. Another app (a
        // call joining, Audio MIDI Setup) can retune the device between holds;
        // rendering with the stale client format fails every callback and the
        // hold records nothing — so check the live hardware on every start.
        if unit == nil || boundDevice != device
            || Self.needsRebuild(built: builtShape, current: Self.inputShape(of: device)) {
            dispose()
            try build(device: device)
        }
        // Fresh session: drop the resampler's tail from the previous hold so
        // it can't bleed into this hold's first buffer, and let a render
        // failure be logged again (once per hold, not once per unit).
        converter?.reset()
        loggedRenderError = false
        guard let unit else { return }
        let status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            // A device that died between holds: rebuild once from scratch.
            dispose()
            try build(device: device)
            guard let rebuilt = self.unit else { return }
            let again = AudioOutputUnitStart(rebuilt)
            guard again == noErr else { throw CaptureError(stage: "AudioOutputUnitStart", status: again) }
            isRunning = true
            return
        }
        isRunning = true
    }

    /// Stop IO (the mic indicator turns off); the unit stays ready.
    func stop() {
        guard isRunning, let unit else { return }
        AudioOutputUnitStop(unit)
        isRunning = false
        onBuffer = nil
    }

    /// Tear the unit down completely (device change, deinit).
    func dispose() {
        if let unit {
            if isRunning { AudioOutputUnitStop(unit) }
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        isRunning = false
        boundDevice = 0
        builtShape = nil
        deviceFormat = nil
        renderBuffer = nil
        converter = nil
        outBuffer = nil
    }

    // MARK: - Build

    private func build(device: AudioDeviceID) throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw CaptureError(stage: "AudioComponentFindNext", status: -1)
        }
        var newUnit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &newUnit), "AudioComponentInstanceNew")
        guard let unit = newUnit else { throw CaptureError(stage: "AudioComponentInstanceNew", status: -1) }
        self.unit = unit

        // Input on (bus 1), output OFF (bus 0): this unit never renders to a
        // speaker, so it never needs — or touches — an output device.
        var on: UInt32 = 1, off: UInt32 = 0
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Input, 1, &on, 4), "EnableIO input")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Output, 0, &off, 4), "DisableIO output")

        var dev = device
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0, &dev, 4), "CurrentDevice")
        boundDevice = device
        builtShape = Self.inputShape(of: device)

        // The device's own input format (rate is fixed by hardware; the AUHAL
        // can't resample) → ask for it as Float32 non-interleaved.
        var hw = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Input, 1, &hw, &size), "StreamFormat (hw)")
        guard hw.mSampleRate > 0, hw.mChannelsPerFrame > 0,
              let client = AVAudioFormat(standardFormatWithSampleRate: hw.mSampleRate,
                                         channels: hw.mChannelsPerFrame) else {
            throw CaptureError(stage: "hardware format", status: -1)
        }
        var clientASBD = client.streamDescription.pointee
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output, 1, &clientASBD, size), "StreamFormat (client)")
        deviceFormat = client

        // Room for the device's IO buffer plus headroom (a device can grow
        // its buffer under load; a short render is just dropped and logged).
        var frames: UInt32 = 0
        var frameSize = UInt32(4)
        AudioUnitGetProperty(unit, kAudioDevicePropertyBufferFrameSize,
                             kAudioUnitScope_Global, 0, &frames, &frameSize)
        let capacity = max(frames * 4, 8192)
        renderBuffer = AVAudioPCMBuffer(pcmFormat: client, frameCapacity: capacity)
        converter = AVAudioConverter(from: client, to: Self.canonicalFormat)
        let ratio = Self.canonicalFormat.sampleRate / client.sampleRate
        outBuffer = AVAudioPCMBuffer(pcmFormat: Self.canonicalFormat,
                                     frameCapacity: AVAudioFrameCount(Double(capacity) * ratio) + 64)

        var callback = AURenderCallbackStruct(
            inputProc: micCaptureInputProc,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                                       kAudioUnitScope_Global, 0, &callback,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "SetInputCallback")
        try check(AudioUnitInitialize(unit), "AudioUnitInitialize")
        loggedRenderError = false
    }

    /// Whether a kept unit must be rebuilt for the device's current format.
    /// An unreadable current shape keeps the unit (a dead device still gets
    /// the rebuild-on-start-failure path); an unknown built shape rebuilds.
    static func needsRebuild(built: HardwareShape?, current: HardwareShape?) -> Bool {
        guard let current else { return false }
        guard let built else { return true }
        return built.channels != current.channels
            || abs(built.sampleRate - current.sampleRate) >= 1
    }

    /// The device's input sample rate + total input channels right now, or
    /// nil if either can't be read.
    static func inputShape(of device: AudioDeviceID) -> HardwareShape? {
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Double = 0
        var rateSize = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device, &rateAddress, 0, nil, &rateSize, &rate) == noErr,
              rate > 0 else { return nil }

        var configAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &configAddress, 0, nil, &size) == noErr,
              size > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(device, &configAddress, 0, nil, &size, list) == noErr else { return nil }
        let channels = UnsafeMutableAudioBufferListPointer(list).reduce(UInt32(0)) { $0 + $1.mNumberChannels }
        return HardwareShape(sampleRate: rate, channels: channels)
    }

    private func check(_ status: OSStatus, _ stage: String) throws {
        guard status == noErr else {
            dispose()
            throw CaptureError(stage: stage, status: status)
        }
    }

    // MARK: - Audio thread

    /// Pull the frames the device just captured, canonicalize, hand off.
    fileprivate func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            _ timestamp: UnsafePointer<AudioTimeStamp>,
                            _ frames: UInt32) {
        guard let unit, let renderBuffer, let outBuffer, let converter, let onBuffer else { return }
        guard frames <= renderBuffer.frameCapacity else {
            if !loggedRenderError {
                loggedRenderError = true
                NSLog("Slive: mic delivered \(frames) frames > capacity \(renderBuffer.frameCapacity) — dropping")
            }
            return
        }
        renderBuffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, timestamp, 1, frames, renderBuffer.mutableAudioBufferList)
        guard status == noErr else {
            if !loggedRenderError {
                loggedRenderError = true
                NSLog("Slive: AudioUnitRender failed (\(status))")
            }
            return
        }

        outBuffer.frameLength = 0
        var fed = false
        var error: NSError?
        converter.convert(to: outBuffer, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return renderBuffer
        }
        if let error {
            if !loggedRenderError {
                loggedRenderError = true
                NSLog("Slive: mic conversion failed: \(error)")
            }
            return
        }
        if outBuffer.frameLength > 0 { onBuffer(outBuffer) }
    }
}

/// C-callable trampoline for the AUHAL input callback.
private func micCaptureInputProc(
    _ refCon: UnsafeMutableRawPointer,
    _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ timestamp: UnsafePointer<AudioTimeStamp>,
    _ bus: UInt32,
    _ frames: UInt32,
    _ data: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let capture = Unmanaged<MicCapture>.fromOpaque(refCon).takeUnretainedValue()
    capture.render(flags, timestamp, frames)
    return noErr
}
