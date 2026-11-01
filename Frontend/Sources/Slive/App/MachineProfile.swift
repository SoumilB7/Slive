import Foundation
import IOKit

/// What this Mac actually is — the checker behind every "this machine" claim
/// in the UI. The speed graph's "maximum reach" tag and its calibration
/// caption both read from here, so the claims are tied to real hardware
/// details, not assumptions baked in from the machine Slive was written on.
enum MachineProfile {
    /// e.g. "Apple M4". Falls back generically rather than guessing.
    static let chip: String = sysctlString("machdep.cpu.brand_string") ?? "Apple silicon"
    static let ramGB: Int = Int(ProcessInfo.processInfo.physicalMemory / (1 << 30))
    /// Performance/efficiency core split (0 when the sysctl is unavailable).
    static let pCores: Int = sysctlInt("hw.perflevel0.physicalcpu") ?? 0
    static let eCores: Int = sysctlInt("hw.perflevel1.physicalcpu") ?? 0

    /// This Mac's battery capacity in watt-hours, read from the smart-battery
    /// controller — the denominator that turns tier power draw into "% of
    /// YOUR battery per hour". nil when there is no battery.
    ///
    /// Verified against real ioreg dumps (M1–M4): capacities are mAh, Voltage
    /// is instantaneous mV (so the Wh figure drifts ±10% with charge state —
    /// fine for a per-hour estimate). Apple silicon DESKTOPS also register
    /// AppleSmartBattery (with BatteryInstalled = false), so the presence of
    /// the service proves nothing — the BatteryInstalled gate is the truth.
    static let batteryWh: Double? = {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func raw(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString,
                                            kCFAllocatorDefault, 0)?
                .takeRetainedValue()
        }
        func prop(_ key: String) -> Double? { (raw(key) as? NSNumber)?.doubleValue }
        guard (raw("BatteryInstalled") as? Bool) == true else { return nil }
        // AppleRawMaxCapacity = true current capacity in mAh; DesignCapacity
        // as fallback. (Plain "MaxCapacity" is a percentage on Apple silicon —
        // the >100 guard keeps that trap out.)
        guard let mAh = prop("AppleRawMaxCapacity") ?? prop("DesignCapacity"),
              let mV = prop("Voltage"), mAh > 100, mV > 1000 else { return nil }
        return mAh * mV / 1_000_000
    }()

    /// One line for the UI: "Apple M4 · 4P+6E · 16 GB · 53 Wh battery".
    static var summary: String {
        var parts = [chip]
        if pCores > 0 { parts.append("\(pCores)P+\(eCores)E") }
        parts.append("\(ramGB) GB")
        if let wh = batteryWh { parts.append("\(Int(wh.rounded())) Wh battery") }
        return parts.joined(separator: " · ")
    }

    // MARK: - sysctl plumbing

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return Int(value)
    }
}
