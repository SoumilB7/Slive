import AppKit
import SwiftUI

/// Owns the Settings/home window. Slive is a normal app (persistent Dock icon),
/// so closing this window just hides it — the app keeps running.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    var onRelaunch: () -> Void = {}

    private var window: NSWindow?
    private let permissions = PermissionsModel(hotkeyActive: { Settings.shared.hotkeyActive })

    /// The one place the settings pages' dependencies are chosen.
    private func makeEnv() -> SettingsEnv {
        SettingsEnv(
            settings: .shared,
            permissions: permissions,
            transcription: .shared,
            providers: .shared,
            trainingStore: .shared,
            labelRun: .shared,
            history: .shared,
            stats: .shared,
            inputDevices: .shared,
            backend: .shared,
            promptLog: .shared,
            player: .shared,
            trainingClient: TrainingClient(),
            promptClient: GroundTruthClient(),
            capabilities: .current,
            relaunch: { [weak self] in self?.onRelaunch() }
        )
    }

    func show() {
        if window == nil {
            let root = SettingsView(env: makeEnv())
            let hosting = NSHostingView(rootView: root)

            let w = NSWindow(
                contentRect: NSRect(origin: .zero, size: SliveTheme.windowDefault),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.title = "Slive"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.collectionBehavior = [.fullScreenPrimary]   // allow entering full screen
            w.minSize = SliveTheme.windowMin              // single source of truth
            w.backgroundColor = SliveTheme.windowBackdrop
            w.contentView = hosting
            w.isReleasedWhenClosed = false
            w.center()
            // Remember the user's chosen size/position across launches.
            w.setFrameAutosaveName(SettingsWindowState.autosaveName)
            w.delegate = self
            window = w
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // The window is kept (not released) on close, so SwiftUI's onAppear
        // doesn't reliably fire again on reopen — restart polling here.
        permissions.startWatching()
    }

    /// A plain close doesn't fire SwiftUI's onDisappear either; without this
    /// the 1 Hz permission poll ran for the rest of the app's lifetime.
    func windowWillClose(_ notification: Notification) {
        permissions.stopWatching()
    }
}

/// The window's remembered geometry: the autosave name AppKit persists the
/// frame under, and the width the root view renders its first frame at.
enum SettingsWindowState {
    static let autosaveName = "SliveSettings"

    /// Seeded from the autosaved window frame so the first frame renders in the
    /// right tier (a compact-restored window shouldn't flash one sidebar frame
    /// before onGeometryChange reports).
    static func initialWidth(_ defaults: UserDefaults = .standard) -> CGFloat {
        width(fromAutosavedFrame: defaults.string(forKey: "NSWindow Frame \(autosaveName)"))
    }

    /// Format: "x y w h screenX …" — width is the third token; any parse
    /// failure falls back to the default size.
    static func width(fromAutosavedFrame frame: String?) -> CGFloat {
        if let frame {
            let tokens = frame.split(separator: " ")
            if tokens.count > 2, let w = Double(tokens[2]), w > 0 {
                return CGFloat(w)
            }
        }
        return SliveTheme.windowDefault.width
    }
}
