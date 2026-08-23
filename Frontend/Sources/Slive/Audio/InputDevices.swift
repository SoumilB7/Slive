import CoreAudio
import Foundation

/// The microphone list — what Google Meet's mic menu shows, for Slive.
///
/// Enumerates every Core Audio device with input channels, tracks the system
/// default, and republishes on plug/unplug so the Settings picker is always
/// current. Devices are persisted by UID (stable across reboots and
/// re-plugs; `AudioDeviceID`s are not), and resolved to a live ID at each
/// recording start — an unplugged pick falls back to the system default
/// rather than failing the recording.
@MainActor
final class InputDevices: ObservableObject {
    static let shared = InputDevices()

    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let transport: String?
        let sampleRate: Double

        /// "Bluetooth · 16 kHz" — the facts that explain how a mic will sound.
        var detail: String {
            var parts: [String] = []
            if let transport { parts.append(transport) }
            parts.append(Self.rateLabel(sampleRate))
            return parts.joined(separator: " · ")
        }

        static func rateLabel(_ hz: Double) -> String {
            guard hz > 0 else { return "rate unknown" }
            let k = hz / 1000
            return k == k.rounded() ? "\(Int(k)) kHz" : String(format: "%.1f kHz", k)
        }
    }

    /// Every input-capable device, system default first.
    @Published private(set) var devices: [Device] = []
    /// The device macOS currently routes default input to.
    @Published private(set) var systemDefault: Device?

    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    private init() {
        refresh()
        // Plug/unplug and default-input changes → refresh on main.
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            }
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
            listeners.append((address, block))
        }
    }

    func refresh() {
        let all = Self.enumerate()
        let defaultID = Self.defaultInputID()
        systemDefault = all.first { $0.id == defaultID }
        devices = all.sorted { a, b in
            if a.id == defaultID { return true }
            if b.id == defaultID { return false }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// The device a saved preference points at right now, or nil when the
    /// preference is "system default" or the device isn't connected.
    func device(forUID uid: String) -> Device? {
        guard !uid.isEmpty else { return nil }
        return devices.first { $0.uid == uid }
    }

    // MARK: - Resolution (callable off-main; pure Core Audio reads)

    /// Live `AudioDeviceID` for a saved preference: nil = follow the system
    /// default (either because that's the preference, or because the chosen
    /// mic is not connected — logged so the fallback is never silent).
    nonisolated static func resolve(uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        if let match = enumerate().first(where: { $0.uid == uid }) { return match.id }
        NSLog("Slive: chosen microphone (\(uid)) is not connected — using the system default")
        return nil
    }

    nonisolated static func defaultInputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    nonisolated static func enumerate() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard inputChannels(of: id) > 0 else { return nil }
            guard let uid = string(of: id, kAudioDevicePropertyDeviceUID),
                  let name = string(of: id, kAudioDevicePropertyDeviceNameCFString) else { return nil }
            return Device(id: id, uid: uid, name: name,
                          transport: transportName(of: id),
                          sampleRate: nominalRate(of: id))
        }
    }

    private nonisolated static func inputChannels(of id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, list) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private nonisolated static func string(of id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private nonisolated static func nominalRate(of id: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }

    private nonisolated static func transportName(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var code: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &code) == noErr else { return nil }
        return transportLabel(code)
    }

    /// Human name for a Core Audio transport code (nil for codes we don't
    /// name — the picker just omits the transport then).
    nonisolated static func transportLabel(_ code: UInt32) -> String? {
        switch code {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless: return "iPhone"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        default: return nil
        }
    }
}
