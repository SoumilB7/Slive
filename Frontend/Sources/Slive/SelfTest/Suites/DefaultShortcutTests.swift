import AppKit
import CoreAudio
import CoreGraphics
import FluidAudio
import SliveObjC
import SliveReport
import SliveTestKit

private let fn = Fixtures.fn

@MainActor
enum DefaultShortcutTests {
    static let suite = TestSuite(name: "Default shortcuts") { t in
        print("[Default shortcuts]")
        t.check(Settings.defaultDictateToggle?.label == "⌃ ×2", "double-tap ⌃ toggles dictation by default")
        t.check(Settings.defaultAssistantHotkey?.label == "⌃fn", "⌃fn asks by default")
        t.check(Settings.suggestedStreamHotkey?.keyCode == 44 && Settings.suggestedStreamToggleHotkey?.keyCode == 47,
              "the live typing suggestion's shortcuts decode (⌥ / and ⌥ .)")
    }
}
