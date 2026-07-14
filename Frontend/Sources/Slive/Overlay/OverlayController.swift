import AppKit
import SwiftUI

/// Hosts the SwiftUI overlay in a borderless, non-activating panel that floats
/// above everything, ignores mouse events (clicks pass straight through to the
/// app underneath), and never steals keyboard focus — essential, since you're
/// dictating *into* another app.
final class OverlayController {
    let model: AudioModel
    private let panel: NSPanel

    init(model: AudioModel) {
        self.model = model

        let size = NSSize(width: 120, height: 44)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false                      // shadow is drawn in SwiftUI
        panel.ignoresMouseEvents = true              // click-through
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        applyTopmostLevel()                          // level + collection behavior

        let host = NSHostingView(rootView: OverlayView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        // Re-assert the top-most level when the environment changes underneath a
        // long-running session: a Space switch, or a wake from sleep, can leave
        // the panel below the frontmost app. See `applyTopmostLevel`.
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reassertTopmost()
            }
        }
    }

    /// Set the panel's window level and collection behavior so it floats above
    /// everything — including other apps' full-screen spaces.
    ///
    /// `CGShieldingWindowLevel()` is the level Apple uses for overlays that must
    /// sit on top of full-screen content (screen dimmers / capture overlays);
    /// `.screenSaver` isn't reliably above a full-screen app's own layers on
    /// recent macOS. Crucially this is re-read on every `show()` (not cached from
    /// launch): the effective shielding level can rise during a long session —
    /// after full-screen apps, screen recording, or a lock/wake — and a stale
    /// level captured at launch would leave the pill rendering BEHIND the
    /// frontmost app (looking like it vanished).
    private func applyTopmostLevel() {
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        // canJoinAllSpaces + fullScreenAuxiliary = shows on every Space and over
        // full-screen apps; stationary = doesn't slide with Spaces.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    /// Refresh the panel's level + collection behavior — used after Space
    /// switches and wake-from-sleep, when the window server can demote the panel
    /// or drop its all-spaces / full-screen behavior. Applied even while hidden
    /// (sleep resets it whether or not the pill is up), so the next appearance
    /// already draws over everything; re-ordered to the front if it's visible.
    private func reassertTopmost() {
        applyTopmostLevel()
        if panel.isVisible { panel.orderFrontRegardless() }
        Log.overlay("reassert level=\(panel.level.rawValue) visible=\(panel.isVisible)")
    }

    /// Bring the overlay on screen, positioned bottom-centre of whichever
    /// screen currently has the mouse. Always resets to the resting pill size —
    /// a previous result box may have left the panel grown.
    func show() {
        panel.ignoresMouseEvents = true              // pill/transcribing stay click-through
        applyTopmostLevel()                          // refresh level (may be stale)
        setPanelSize(OverlayMetrics.pillSize)
        reposition()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        panel.ignoresMouseEvents = true              // reset to click-through
        // Reset for the next appearance so it never flashes at the grown size.
        setPanelSize(OverlayMetrics.pillSize)
    }

    /// Opt-in interactivity. The overlay is click-through by default; the app
    /// enables this only while a result box (with its copy button) is showing,
    /// then disables it again on collapse. The panel stays a non-activating
    /// panel throughout, so receiving a click never steals focus from the app
    /// the user is dictating into.
    func setInteractive(_ interactive: Bool) {
        panel.ignoresMouseEvents = !interactive
    }

    /// Grow (or shrink) the panel to fit the given content size, keeping it
    /// bottom-centred so the box grows upward with a fixed bottom edge.
    func resize(to size: NSSize) {
        setPanelSize(size)
        reposition()
    }

    private func setPanelSize(_ size: NSSize) {
        var frame = panel.frame
        // Keep the bottom edge fixed while the size changes; `reposition` then
        // recentres horizontally.
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    private func reposition() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.minY + 8                         // lower, near the bottom edge
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
