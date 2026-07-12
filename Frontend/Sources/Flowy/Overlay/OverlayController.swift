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
        // Above everything — including fullscreen apps and other floating HUDs.
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false                      // shadow is drawn in SwiftUI
        panel.ignoresMouseEvents = true              // click-through
        panel.hidesOnDeactivate = false
        // canJoinAllSpaces + fullScreenAuxiliary = shows on every Space and
        // over apps that are in fullscreen; stationary = doesn't slide with Spaces.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false

        let host = NSHostingView(rootView: OverlayView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    /// Bring the overlay on screen, positioned bottom-centre of whichever
    /// screen currently has the mouse. Always resets to the resting pill size —
    /// a previous result box may have left the panel grown.
    func show() {
        setPanelSize(OverlayMetrics.pillSize)
        reposition()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        // Reset for the next appearance so it never flashes at the grown size.
        setPanelSize(OverlayMetrics.pillSize)
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
