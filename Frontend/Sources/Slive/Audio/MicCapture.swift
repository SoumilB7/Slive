import Accelerate
import AudioToolbox
import AVFoundation
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
/// Multichannel devices are averaged to mono here (Sep 2026: after macOS
/// 26.6.2 the MacBook Air's built-in mic presents its raw 3-mic array —
/// 3 ch / 48 kHz, channels equal-level and ~0.9 correlated — where it used to
/// present 1 ch; the old `standardFormatWithSampleRate:channels:` returns nil
/// above 2 channels, so every hold failed before audio flowed).
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

    private var unit: AudioUnit?
    private var boundDevice: AudioDeviceID = 0
    private(set) var deviceFormat: AVAudioFormat?
    private var renderBuffer: AVAudioPCMBuffer?
    /// Mono mixdown of `renderBuffer` (multichannel devices only; nil = mono device).
    private var monoBuffer: AVAudioPCMBuffer?
    private var converter: AVAudioConverter?
    private var outBuffer: AVAudioPCMBuffer?
    private(set) var isRunning = false
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var loggedRenderError = false

    deinit { dispose() }

    /// Start IO on `device`, rebuilding the unit if it was built for another
    /// device (or never). Throws with the failing stage + OSStatus.
    func start(device: AudioDeviceID, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        if isRunning { return }
        self.onBuffer = onBuffer
        if unit == nil || boundDevice != device {
            dispose()
            try build(device: device)
        }
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
        deviceFormat = nil
        renderBuffer = nil
        monoBuffer = nil
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

        // The device's own input format (rate is fixed by hardware; the AUHAL
        // can't resample) → ask for it as Float32 non-interleaved.
        var hw = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Input, 1, &hw, &size), "StreamFormat (hw)")
        guard hw.mSampleRate > 0, hw.mChannelsPerFrame > 0,
              let client = Self.clientFormat(sampleRate: hw.mSampleRate,
                                             channels: hw.mChannelsPerFrame),
              let mono = AVAudioFormat(standardFormatWithSampleRate: hw.mSampleRate, channels: 1) else {
            dispose()
            throw CaptureError(stage: "hardware format \(hw.mSampleRate) Hz/\(hw.mChannelsPerFrame) ch",
                               status: -1)
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
        monoBuffer = client.channelCount > 1
            ? AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: capacity) : nil
        // The converter only ever resamples MONO → canonical; the channel
        // mixdown is ours (no reliance on AVAudioConverter downmixing a
        // discrete multichannel layout).
        converter = AVAudioConverter(from: mono, to: Self.canonicalFormat)
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

    /// Float32 non-interleaved at the device's rate and channel count. Above
    /// 2 channels AVAudioFormat needs an explicit layout (the standard
    /// initializer returns nil), so those get a discrete in-order layout.
    static func clientFormat(sampleRate: Double, channels: AVAudioChannelCount) -> AVAudioFormat? {
        guard sampleRate > 0, channels > 0 else { return nil }
        if channels <= 2 {
            return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)
        }
        guard let layout = AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)) else { return nil }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                             interleaved: false, channelLayout: layout)
    }

    /// Average every channel of `source` into mono `dest` (vDSP, no
    /// allocation — safe on the audio thread). Equal weights: an array's
    /// mics carry the same voice, so speech keeps its level while
    /// uncorrelated noise drops a little.
    static func downmix(_ source: AVAudioPCMBuffer, into dest: AVAudioPCMBuffer) {
        let frames = Int(source.frameLength)
        let channels = Int(source.format.channelCount)
        guard frames > 0, frames <= Int(dest.frameCapacity), channels > 0,
              let src = source.floatChannelData, let dst = dest.floatChannelData?[0] else {
            dest.frameLength = 0
            return
        }
        dst.update(from: src[0], count: frames)
        for ch in 1..<max(channels, 1) {
            vDSP_vadd(dst, 1, src[ch], 1, dst, 1, vDSP_Length(frames))
        }
        var scale = 1 / Float(channels)
        vDSP_vsmul(dst, 1, &scale, dst, 1, vDSP_Length(frames))
        dest.frameLength = AVAudioFrameCount(frames)
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

        // Multichannel → mono first; the converter only resamples.
        let source: AVAudioPCMBuffer
        if let monoBuffer {
            Self.downmix(renderBuffer, into: monoBuffer)
            source = monoBuffer
        } else {
            source = renderBuffer
        }

        outBuffer.frameLength = 0
        var fed = false
        var error: NSError?
        converter.convert(to: outBuffer, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return source
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
