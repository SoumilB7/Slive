import AppKit
import SwiftUI

/// Hosts the SwiftUI overlay in a borderless, non-activating panel that floats
/// above everything, ignores mouse events (clicks pass straight through to the
/// app underneath), and never steals keyboard focus — essential, since you're
/// dictating *into* another app.
///
/// ## Why this class is paranoid
///
/// A lid close (sleep + screen lock) — and sometimes a plain lock or display
/// reconfiguration — can corrupt the panel in ways that are invisible from
/// inside the process: the window server tears down the panel's backing (the
/// lock shield sits at our exact window level) or freezes its layer across the
/// GPU reset, while `isVisible` keeps reporting `true`. `orderFrontRegardless()`
/// then becomes a silent no-op: dictation still works, but the pill never
/// appears. Patching individual causes (stale level, lost Space association)
/// proved whack-a-mole, so instead:
///
///  1. **Rebuild on corrupting events.** Wake, screen-wake, unlock, and display
///     reconfiguration throw the whole panel away and build a fresh one (~ms).
///     A new window has fresh level, Space association, backing, and layer —
///     every stale-state class cleared at once.
///  2. **Trust, but verify.** After every `show()`, ask the *window server*
///     whether the panel actually made it on screen (`occlusionState`) — unlike
///     `isVisible`, that's the server's truth. At shielding level nothing can
///     legitimately cover us, so "ordered in but not visible" means the panel
///     is corrupt → rebuild once and re-present. This net catches any cause we
///     haven't imagined; an invisible pill can never *stay* invisible.
///  3. The visibility heartbeat re-asserts the level while the pill is up and
///     runs the same occlusion check, so mid-session death self-heals in ≤2s.
final class OverlayController {
    let model: AudioModel
    private var panel: NSPanel

    /// While the pill is on screen, re-asserts the top-most level on a slow
    /// cadence. A long-running session (especially continuous dictation, which
    /// can stay up for minutes while you work in another app) is exactly when the
    /// window server quietly demotes the panel. Space-change / wake notifications
    /// don't cover every such case; a low-frequency heartbeat does.
    private var topmostTimer: Timer?
    /// Pending post-`show()` occlusion check (cancelled by `hide()`).
    private var verifyWorkItem: DispatchWorkItem?
    /// Whether the result box's buttons are currently clickable — kept so a
    /// rebuild can restore the same interactivity on the fresh panel.
    private var interactive = false

    init(model: AudioModel) {
        self.model = model
        panel = Self.makePanel(model: model)
        applyTopmostLevel()

        let wc = NSWorkspace.shared.notificationCenter

        // Rare, corrupting events → full rebuild (cheap, and definitive).
        // A lid close isn't always a "wake": in clamshell with an external
        // display only the screen set changes, and a plain lock never sleeps
        // the machine — so listen for all four.
        for name in [NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification] {
            wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.rebuildPanel(reason: "wake")
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in self?.rebuildPanel(reason: "unlock") }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.rebuildPanel(reason: "displayChange") }

        // Frequent, benign events → light re-assert only. Another app coming to
        // the front is the common trigger for the pill slipping behind while you
        // work elsewhere; reassert immediately rather than waiting on the
        // heartbeat.
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reassertTopmost()
            }
        }
    }

    /// Build a fully configured overlay panel + SwiftUI host. All panel state
    /// lives here so a rebuild is guaranteed to reproduce the original setup.
    private static func makePanel(model: AudioModel) -> NSPanel {
        let size = OverlayMetrics.pillSize
        let panel = NSPanel(
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

        let host = NSHostingView(rootView: OverlayView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    /// Replace the panel with a freshly built one, carrying over frame,
    /// interactivity, and on-screen-ness. The SwiftUI content re-binds to the
    /// same `AudioModel`, so whatever phase the overlay was showing redraws
    /// identically on the new window.
    private func rebuildPanel(reason: String) {
        let wasVisible = panel.isVisible
        let frame = panel.frame
        panel.orderOut(nil)
        panel = Self.makePanel(model: model)
        applyTopmostLevel()
        panel.setFrame(frame, display: true)
        panel.ignoresMouseEvents = !interactive
        if wasVisible {
            reposition()
            panel.orderFrontRegardless()
        }
        Log.overlay("rebuilt panel (\(reason)) wasVisible=\(wasVisible)")
    }

    /// Set the panel's window level and collection behavior so it floats above
    /// everything — including other apps' full-screen spaces.
    ///
    /// `CGShieldingWindowLevel()` is the level Apple uses for overlays that must
    /// sit on top of full-screen content (screen dimmers / capture overlays);
    /// `.screenSaver` isn't reliably above a full-screen app's own layers on
    /// recent macOS. Re-read on every `show()` rather than cached from launch.
    private func applyTopmostLevel() {
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        // canJoinAllSpaces + fullScreenAuxiliary = shows on every Space and over
        // full-screen apps; stationary = doesn't slide with Spaces.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    /// Refresh the panel's level + collection behavior — used after Space
    /// switches and app activations, when the window server can demote the panel
    /// or drop its all-spaces / full-screen behavior. Applied even while hidden,
    /// so the next appearance already draws over everything; re-ordered to the
    /// front if it's visible.
    private func reassertTopmost() {
        applyTopmostLevel()
        if panel.isVisible { panel.orderFrontRegardless() }
        Log.overlay("reassert level=\(panel.level.rawValue) visible=\(panel.isVisible)")
    }

    /// Bring the overlay on screen, positioned bottom-centre of whichever
    /// screen currently has the mouse. Always resets to the resting pill size —
    /// a previous result box may have left the panel grown.
    func show() {
        interactive = false
        panel.ignoresMouseEvents = true              // pill/transcribing stay click-through
        applyTopmostLevel()                          // refresh level (may be stale)
        setPanelSize(OverlayMetrics.pillSize)
        reposition()
        panel.orderFrontRegardless()
        startTopmostHeartbeat()
        verifyOnScreen()
        Log.overlay("show frame=\(panel.frame) level=\(panel.level.rawValue)")
    }

    func hide() {
        stopTopmostHeartbeat()
        verifyWorkItem?.cancel(); verifyWorkItem = nil
        panel.orderOut(nil)
        interactive = false
        panel.ignoresMouseEvents = true              // reset to click-through
        // Reset for the next appearance so it never flashes at the grown size.
        setPanelSize(OverlayMetrics.pillSize)
    }

    /// Trust, but verify: shortly after ordering in, ask the window server
    /// whether any part of the panel is actually on screen. `isVisible` only
    /// records that *we asked* for it to be on screen; `occlusionState` reports
    /// whether it *is*. Nothing can legitimately cover a shielding-level window,
    /// so "ordered in but not visible" means the panel's backing died (lid
    /// close / lock) — rebuild once and re-present. Single-shot: a rebuilt panel
    /// that still can't present (screen locked) just waits for the next show().
    private func verifyOnScreen() {
        verifyWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.panel.isVisible else { return }
            if !self.panel.occlusionState.contains(.visible) {
                self.rebuildPanel(reason: "orderedIn-but-offscreen")
            }
        }
        verifyWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// While the pill is visible: keep the level asserted, and if the window
    /// server reports us gone from screen (backing died mid-session), rebuild.
    /// Ordering an already-frontmost non-activating panel forward is a visual
    /// no-op and never steals focus, so this is safe on a loop.
    private func startTopmostHeartbeat() {
        guard topmostTimer == nil else { return }
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard self.panel.isVisible else { self.stopTopmostHeartbeat(); return }
            if !self.panel.occlusionState.contains(.visible) {
                self.rebuildPanel(reason: "heartbeat-offscreen")
            } else {
                self.applyTopmostLevel()
                self.panel.orderFrontRegardless()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        topmostTimer = t
    }

    private func stopTopmostHeartbeat() {
        topmostTimer?.invalidate()
        topmostTimer = nil
    }

    /// Opt-in interactivity. The overlay is click-through by default; the app
    /// enables this only while a result box (with its copy button) is showing,
    /// then disables it again on collapse. The panel stays a non-activating
    /// panel throughout, so receiving a click never steals focus from the app
    /// the user is dictating into.
    func setInteractive(_ interactive: Bool) {
        self.interactive = interactive
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
        // Fall back through mouse-screen → main → first available, so a screen
        // reconfiguration (lid close with an external display) can never leave
        // us with no frame and the pill stranded at stale off-screen coordinates.
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.minY + 8                         // lower, near the bottom edge
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
