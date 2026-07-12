import AppKit

/// Captures the screen for the assistant's "attach a screenshot" option.
enum ScreenCapture {
    /// Capture the full screen as a PNG and return (mediaType, base64 data).
    /// Returns nil on failure — including when Screen Recording permission is
    /// missing (macOS then yields a blank/empty capture).
    ///
    /// Blocks on the `screencapture` subprocess, so call it off the main thread.
    static func fullScreenBase64() -> (mediaType: String, data: String)? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowy-shot-\(UUID().uuidString).png")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -x: silent (no shutter sound/UI), -t png: PNG, main display to file.
        task.arguments = ["-x", "-t", "png", tmp.path]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            NSLog("Flowy: screencapture failed to launch — \(error)")
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        guard task.terminationStatus == 0,
              let data = try? Data(contentsOf: tmp), !data.isEmpty else {
            NSLog("Flowy: screenshot capture produced no image (Screen Recording permission?)")
            return nil
        }
        return ("image/png", data.base64EncodedString())
    }
}
