import AppKit
import Combine

/// The app's main menu (standard shortcuts) and the menu-bar status item,
/// whose status line follows the backend.
@MainActor final class MenuBarController: NSObject {
    private let backend: BackendManager
    private let settingsWindow: SettingsWindowController

    private var statusItem: NSStatusItem?
    private var backendStatusItem: NSMenuItem?
    private var statusCancellable: AnyCancellable?

    init(backend: BackendManager, settingsWindow: SettingsWindowController) {
        self.backend = backend
        self.settingsWindow = settingsWindow
    }

    /// Subscribe to the backend status, then build both menus.
    func install() {
        statusCancellable = backend.$status.sink { [weak self] status in
            self?.updateBackendStatusUI(status)
        }
        setupMainMenu()
        setupMenuBar()
    }

    // MARK: - Main menu (standard app shortcuts)

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // Application menu — About, Settings, Hide, Quit.
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Slive",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…",
                                       action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        let report = appMenu.addItem(withTitle: "Report a Problem…",
                                     action: #selector(reportProblem), keyEquivalent: "")
        report.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Slive",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Slive",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu — REQUIRED for Cut/Copy/Paste/Select All to work in text
        // fields. Without it, ⌘V (and ⌘C/⌘X/⌘A/⌘Z) have no menu item carrying
        // the key equivalent, so AppKit never dispatches them to the focused
        // field's editor — you literally can't paste an API key. These
        // nil-target selectors travel the responder chain to the field editor.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // Window menu — Minimize, Zoom, Close.
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close",
                           action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - Menu bar

    private func setupMenuBar() {
        let item = NSStatusItem.button(in: NSStatusBar.system)
        item.button?.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "Slive"
        )
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        let header = NSMenuItem(title: "Slive", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        // Live backend status (updated via the Combine subscription).
        if Capabilities.current.server {
            let statusLine = NSMenuItem(title: "…", action: nil, keyEquivalent: "")
            statusLine.isEnabled = false
            menu.addItem(statusLine)
            backendStatusItem = statusLine
            updateBackendStatusUI(backend.status)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let reportItem = NSMenuItem(title: "Report a Problem…",
                                    action: #selector(reportProblem), keyEquivalent: "")
        reportItem.target = self
        menu.addItem(reportItem)

        menu.addItem(.separator())
        // Quit has no explicit target: it travels the responder chain to NSApp.
        menu.addItem(NSMenuItem(title: "Quit Slive",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc func openSettings() {
        settingsWindow.show()
    }

    /// Opens a GitHub issue prefilled with this build and Slive's recent log
    /// (through the reporter, which strips anything personal first).
    @objc private func reportProblem() {
        FailureReporter.shared.reportManually()
    }

    /// Reflect the backend status in the menu-bar item (tooltip + menu line).
    private func updateBackendStatusUI(_ status: BackendManager.Status) {
        statusItem?.button?.toolTip = "Slive"
        backendStatusItem?.title = status == .running ? "Ready" : status.rawValue
    }
}

private extension NSStatusItem {
    /// Small helper so `setupMenuBar` reads cleanly.
    static func button(in bar: NSStatusBar) -> NSStatusItem {
        bar.statusItem(withLength: NSStatusItem.variableLength)
    }
}
