import CoreGraphics
import Foundation
import ServiceManagement

/// The push-to-talk keys the user can pick from. Each maps to the physical key
/// code that changes on a `flagsChanged` event plus the modifier bit that marks
/// it "down" — the two facts `HotkeyMonitor` needs to detect a hold.
enum HotkeyChoice: String, CaseIterable, Identifiable {
    case fn
    case rightCommand
    case rightOption
    case rightControl

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fn:           return "fn  🌐"
        case .rightCommand: return "Right ⌘"
        case .rightOption:  return "Right ⌥"
        case .rightControl: return "Right ⌃"
        }
    }

    var subtitle: String {
        switch self {
        case .fn:           return "The Globe key — same as macOS dictation"
        case .rightCommand: return "Right Command, out of the way of shortcuts"
        case .rightOption:  return "Right Option, left Option stays free"
        case .rightControl: return "Right Control"
        }
    }

    /// Physical key code reported in `keyboardEventKeycode` on flagsChanged.
    var keycode: Int64 {
        switch self {
        case .fn:           return 63   // kVK_Function
        case .rightCommand: return 54   // kVK_RightCommand
        case .rightOption:  return 61   // kVK_RightOption
        case .rightControl: return 62   // kVK_RightControl
        }
    }

    /// Modifier bit that is set while the key is held.
    var mask: CGEventFlags {
        switch self {
        case .fn:           return .maskSecondaryFn
        case .rightCommand: return .maskCommand
        case .rightOption:  return .maskAlternate
        case .rightControl: return .maskControl
        }
    }
}

/// App-wide, persisted preferences. Backed by `UserDefaults`; observable so the
/// SwiftUI Settings window stays in sync.
final class Settings: ObservableObject {
    static let shared = Settings()

    private enum Keys {
        static let hotkey = "hotkey"
        static let launchAtLogin = "launchAtLogin"
        static let didFirstRun = "didFirstRun"
    }

    /// Fired whenever the hotkey changes, so the monitor can re-target.
    var onHotkeyChange: ((HotkeyChoice) -> Void)?

    @Published var hotkey: HotkeyChoice {
        didSet {
            UserDefaults.standard.set(hotkey.rawValue, forKey: Keys.hotkey)
            onHotkeyChange?(hotkey)
        }
    }

    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin(launchAtLogin) }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Keys.hotkey)
        hotkey = raw.flatMap(HotkeyChoice.init(rawValue:)) ?? .fn
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
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
