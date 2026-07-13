import AVFoundation
import AppKit
import ApplicationServices
import IOKit.hid

/// Live view of the two permissions Slive needs, so the Settings window can
/// show real status and offer one-tap granting. Polls while the window is open.
final class PermissionsModel: ObservableObject {
    @Published var micGranted = false
    @Published var inputMonitoringGranted = false
    @Published var accessibilityGranted = false

    private var timer: Timer?

    func startWatching() {
        refresh()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        inputMonitoringGranted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        accessibilityGranted = AXIsProcessTrusted()
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
