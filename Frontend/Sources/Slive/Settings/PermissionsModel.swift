import AVFoundation
import AppKit
import ApplicationServices
import IOKit.hid

/// Live view of the permissions Slive needs, so the Settings window can
/// show real status and offer one-tap granting. Polls while the window is open.
final class PermissionsModel: ObservableObject {
    @Published var micGranted = false
    @Published var inputMonitoringGranted = false
    @Published var accessibilityGranted = false
    /// The event tap has delivered a keystroke (polled with the grants, so
    /// the status updates when it starts working).
    @Published private(set) var hotkeyWorks = false

    /// Input Monitoring, Microphone, Accessibility.
    static let required = 3

    private var timer: Timer?
    /// True once the event tap has delivered a keystroke — proof Input
    /// Monitoring works even when IOHIDCheckAccess's cached answer says no.
    private let hotkeyActive: () -> Bool

    /// What macOS says right now: microphone, Input Monitoring, Accessibility.
    struct Grants {
        var mic: Bool
        var inputMonitoring: Bool
        var accessibility: Bool

        static func system() -> Grants {
            Grants(mic: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                   inputMonitoring: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted,
                   accessibility: AXIsProcessTrusted())
        }
    }

    /// Reads the grants (fixed in the Settings render self-test).
    private let probe: () -> Grants

    init(hotkeyActive: @escaping () -> Bool = { false }, probe: @escaping () -> Grants = Grants.system) {
        self.hotkeyActive = hotkeyActive
        self.probe = probe
    }

    /// Input Monitoring as the user experiences it: granted, or demonstrably
    /// working.
    var inputMonitoringWorks: Bool { inputMonitoringGranted || hotkeyWorks }

    var grantedCount: Int {
        [inputMonitoringWorks, micGranted, accessibilityGranted].filter { $0 }.count
    }

    /// Something is still missing — the sidebar's orange dot.
    var needsAttention: Bool { grantedCount < Self.required }

    /// Idempotent: the window controller (every show) and SettingsView's
    /// onAppear both call this — a second timer would never be invalidated.
    func startWatching() {
        refresh()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 0.3   // let macOS coalesce the wakeup (battery)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    /// Publishes only what changed: an unchanged poll re-rendered the whole
    /// Settings window every second (the Settings render self-test).
    func refresh() {
        let grants = probe()
        if micGranted != grants.mic { micGranted = grants.mic }
        if inputMonitoringGranted != grants.inputMonitoring { inputMonitoringGranted = grants.inputMonitoring }
        if accessibilityGranted != grants.accessibility { accessibilityGranted = grants.accessibility }
        let tap = hotkeyActive()
        if hotkeyWorks != tap { hotkeyWorks = tap }
    }

    // MARK: - Requests

    func requestMic() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            // First time — this shows the system prompt.
            NSApp.activate(ignoringOtherApps: true)
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
        case .denied, .restricted:
            // Already decided — macOS won't re-prompt, so open the pane directly.
            openPane("Privacy_Microphone")
        case .authorized:
            break
        @unknown default:
            openPane("Privacy_Microphone")
        }
    }

    private func openPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
        refresh()
    }

    func requestInputMonitoring() {
        // Surface the system prompt, then take the user to the exact pane.
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
        refresh()
    }

    func requestAccessibility() {
        // Surface the system prompt, then take the user to the exact pane.
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        openPane("Privacy_Accessibility")
    }
}
