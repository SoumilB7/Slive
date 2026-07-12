import AVFoundation
import AppKit
import IOKit.hid

/// Live view of the two permissions Flowy needs, so the Settings window can
/// show real status and offer one-tap granting. Polls while the window is open.
final class PermissionsModel: ObservableObject {
    @Published var micGranted = false
    @Published var inputMonitoringGranted = false

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
    }

    // MARK: - Requests

    func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    func requestInputMonitoring() {
        // Surface the system prompt, then take the user to the exact pane.
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
        refresh()
    }
}
