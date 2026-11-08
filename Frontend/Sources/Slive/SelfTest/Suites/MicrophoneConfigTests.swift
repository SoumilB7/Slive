import CoreAudio
import SliveTestKit

/// The microphone a recording opens, for every saved pick against the
/// devices actually plugged in — none, the pick unplugged, a Bluetooth
/// headset (its :input side is the only one listed), a re-plugged device
/// with a new UID, the default moving, aggregates — and the capture options
/// every setting combination produces. Fake device lists; no Core Audio.
@MainActor
enum MicrophoneConfigTests {
    typealias Device = InputDevices.Device

    static let builtIn = Device(id: 91, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone",
                                transport: "Built-in", sampleRate: 48_000)
    static let headset = Device(id: 92, uid: "00-1A-7D-DA-71-13:input", name: "HP H250",
                                transport: "Bluetooth", sampleRate: 16_000)
    static let usb = Device(id: 93, uid: "AppleUSBAudioEngine:Blue:Yeti:1", name: "Yeti",
                            transport: "USB", sampleRate: 48_000)
    static let aggregate = Device(id: 94, uid: "com.apple.aggregate.slive-test", name: "Aggregate Device",
                                  transport: "Aggregate", sampleRate: 44_100)
    static let iPhone = Device(id: 95, uid: "continuity-mic", name: "iPhone Microphone",
                               transport: "iPhone", sampleRate: 48_000)
    static let virtual = Device(id: 96, uid: "BlackHole2ch_UID", name: "BlackHole 2ch",
                                transport: nil, sampleRate: 0)
    /// The headset's playback side: never an input, so never listed.
    static let headsetOutputUID = "00-1A-7D-DA-71-13:output"
    /// What a pick can be besides a listed device.
    static let missingUIDs = ["gone-mic", headsetOutputUID, "AppleUSBAudioEngine:Blue:Yeti:2"]

    static let deviceSets: [(name: String, devices: [Device])] = [
        ("no microphones", []),
        ("built-in only", [builtIn]),
        ("headset only (lid closed)", [headset]),
        ("built-in + Bluetooth headset", [builtIn, headset]),
        ("everything", [virtual, usb, headset, iPhone, aggregate, builtIn]),
    ]

    static let suite = TestSuite(name: "Microphone configs") { t in
        print("[Microphone configs]")
        var picks = Sweep(), lists = Sweep(), lookups = Sweep()
        for (name, devices) in deviceSets {
            // The OS default may be any listed mic, nothing, or a device we
            // don't list (an output-only default, or one that just vanished).
            let defaults: [AudioDeviceID?] = [nil, 97] + devices.map(\.id)
            for defaultID in defaults {
                // The picker's list: default first (if it's an input), then by name.
                let (ordered, systemDefault) = InputDevices.ordered(devices, defaultID: defaultID)
                let listedDefault = devices.first { $0.id == defaultID }
                let rest = ordered.filter { $0.id != listedDefault?.id }.map(\.name)
                lists.expect(Set(ordered) == Set(devices) && ordered.count == devices.count
                             && systemDefault == listedDefault
                             && (listedDefault == nil || ordered.first == listedDefault)
                             && rest == rest.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                             && InputDevices.ordered(devices.reversed(), defaultID: defaultID).devices == ordered,
                             "\(name) default \(String(describing: defaultID)): \(ordered.map(\.name))")

                let model = InputDevices(devices: ordered, systemDefault: systemDefault)
                for uid in [""] + devices.map(\.uid) + missingUIDs {
                    let listed = devices.first { $0.uid == uid }
                    lookups.expect(model.device(forUID: uid) == listed, "\(name): \(uid)")
                    // The mic a recording opens: the pick if plugged in, else the default.
                    var askedDefault = false
                    var reported: [String] = []
                    let opened = InputDevices.captureDevice(
                        uid: uid, devices: { devices },
                        systemDefault: { askedDefault = true; return defaultID },
                        missing: { reported.append($0) })
                    let want = listed?.id ?? defaultID
                    picks.expect(opened == want && askedDefault == (listed == nil)
                                 && InputDevices.match(uid: uid, among: devices) == listed?.id
                                 // an unplugged pick's fallback is always reported
                                 && reported == (uid.isEmpty || listed != nil ? [] : [uid]),
                                 "\(name) default \(String(describing: defaultID)) pick '\(uid)': opened \(String(describing: opened))")
                }
            }
        }
        lists.report(&t, "picker list: every input once, the default first, the rest by name, any order in")
        lookups.report(&t, "a saved pick is found only while that exact UID is plugged in")
        picks.report(&t, "a recording opens the pick, else the system default; nil only with no input at all")

        t.check(InputDevices.captureDevice(uid: headset.uid, devices: { [] }, systemDefault: { nil },
                                           missing: { _ in }) == nil
                && InputDevices.captureDevice(uid: "", devices: { [] }, systemDefault: { nil }) == nil,
                "no microphones and no default: nothing to open (the recording refuses, it doesn't guess)")
        var listedDevices = 0
        let empty = InputDevices.captureDevice(uid: "", devices: { listedDevices += 1; return [] }, systemDefault: { 7 })
        t.check(empty == 7 && listedDevices == 0, "\"System default\" never enumerates devices")

        // The picker's facts for every kind of device.
        var details = Sweep()
        for device in deviceSets.last!.devices {
            details.expect(!device.detail.isEmpty && !device.name.isEmpty, "\(device.name): '\(device.detail)'")
        }
        details.expect(Device.rateLabel(0) == "rate unknown" && virtual.detail == "rate unknown", virtual.detail)
        let knownTransports: [UInt32] = [
            kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
            kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeHDMI,
            kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeAirPlay,
            kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless,
            kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
        ]
        for code in knownTransports { details.expect(InputDevices.transportLabel(code) != nil, "transport \(code)") }
        details.report(&t, "every device shows a name and a detail line; every Core Audio transport is named")

        // Every setting combination → capture options and backend.
        var options = Sweep()
        let s = Settings(store: InMemoryStore())
        t.check(CaptureOptions.from(s) == CaptureOptions(), "fresh install: system default mic, no echo cancellation")
        for uid in [""] + deviceSets.last!.devices.map(\.uid) + missingUIDs {
            for echo in [false, true] {
                s.inputDeviceUID = uid
                s.echoCancellation = echo
                let o = CaptureOptions.from(s)
                // Echo cancellation runs the voice-processing engine, which
                // follows the system default route (the pick is ignored);
                // otherwise direct capture opens exactly the pick.
                options.expect(o == CaptureOptions(deviceUID: uid, echoCancellation: echo)
                               && AudioRecorder.usesEngine(echoCancellation: o.echoCancellation) == echo,
                               "uid '\(uid)' echo \(echo): \(o)")
            }
        }
        options.report(&t, "every mic pick × echo setting gives the matching capture options and backend")
    }
}
