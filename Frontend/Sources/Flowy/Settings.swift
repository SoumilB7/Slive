import CoreGraphics
import Foundation
import ServiceManagement

/// App-wide, persisted preferences. Backed by `UserDefaults`; observable so the
/// SwiftUI Settings window stays in sync.
final class Settings: ObservableObject {
    static let shared = Settings()

    private enum Keys {
        static let hotkey = "hotkey"
        static let launchAtLogin = "launchAtLogin"
        static let autoInsert = "autoInsert"
        static let hotwords = "hotwords"
        static let contextPrompt = "contextPrompt"
        static let didFirstRun = "didFirstRun"
    }

    /// Fired whenever the hotkey changes, so the monitor can re-target.
    var onHotkeyChange: ((Hotkey) -> Void)?

    /// The user-recorded push-to-talk shortcut. Persisted as JSON.
    @Published var hotkey: Hotkey {
        didSet {
            if let data = try? JSONEncoder().encode(hotkey) {
                UserDefaults.standard.set(data, forKey: Keys.hotkey)
            }
            onHotkeyChange?(hotkey)
        }
    }

    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin(launchAtLogin) }
    }

    /// When enabled, transcripts are inserted straight into the focused editable
    /// text field (when possible) instead of surfacing the copy box.
    @Published var autoInsert: Bool {
        didSet { UserDefaults.standard.set(autoInsert, forKey: Keys.autoInsert) }
    }

    /// Custom vocabulary — names, jargon, acronyms — sent with each request so
    /// the model spells them the way the user expects.
    @Published var hotwords: String {
        didSet { UserDefaults.standard.set(hotwords, forKey: Keys.hotwords) }
    }

    /// A sentence of context that steers the transcription (optional).
    @Published var contextPrompt: String {
        didSet { UserDefaults.standard.set(contextPrompt, forKey: Keys.contextPrompt) }
    }

    /// Ground truth: true once the event tap has actually delivered a keystroke.
    /// Proof that Input Monitoring is genuinely working, regardless of the
    /// cache-prone IOHIDCheckAccess API.
    @Published var hotkeyActive = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: Keys.hotkey),
           let decoded = try? JSONDecoder().decode(Hotkey.self, from: data) {
            hotkey = decoded
        } else {
            hotkey = .fnDefault
        }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        // Default TRUE: absent key means the user hasn't opted out yet.
        if UserDefaults.standard.object(forKey: Keys.autoInsert) == nil {
            autoInsert = true
        } else {
            autoInsert = UserDefaults.standard.bool(forKey: Keys.autoInsert)
        }
        hotwords = UserDefaults.standard.string(forKey: Keys.hotwords) ?? ""
        contextPrompt = UserDefaults.standard.string(forKey: Keys.contextPrompt) ?? ""
    }

    var isFirstRun: Bool {
        !UserDefaults.standard.bool(forKey: Keys.didFirstRun)
    }

    func markFirstRunComplete() {
        UserDefaults.standard.set(true, forKey: Keys.didFirstRun)
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("Flowy: launch-at-login toggle failed: \(error)")
        }
    }
}
