import SwiftUI
import AppKit
import CoreGraphics

/// Records a push-to-talk shortcut: click Record, then press any combo — a
/// modifier alone (fn, ⌥, ⌃⌥, …) or a chord with a key (⌥ + /). Uses a local
/// NSEvent monitor (the Settings window is focused during recording), so it
/// needs no special permission and never leaks the keys into the app.
///
/// It refuses a shortcut that can't work (⇧ + a typing key, a bare ⇧ or ⌘
/// hold, another enabled shortcut's exact gesture), says why and keeps
/// listening; one that only overlaps another is saved and the row warns.
struct HotkeyRecorderView: View {
    /// The page's env settings (in memory in the Settings render self-test).
    @ObservedObject var settings: Settings
    /// Which shortcut this recorder edits.
    var target: BindingSlot = .dictation
    var title: String = "Shortcut"
    /// Optional idle line under the title; the recording prompt replaces it.
    var subtitle: String = ""
    /// Which actions this build runs (one it can't run never clashes).
    var capabilities: Capabilities = .current

    @State private var recording = false
    @State private var monitor: Any?
    /// Turns the monitor's events into outcomes (and owns the ×2 wait).
    @State private var capture = ShortcutCapture()
    /// Why the last press wasn't saved (shown while still recording).
    @State private var refusal: String?

    /// Toggle binds may be a double-tap; hold binds are always a single hold.
    private var supportsDoubleTap: Bool { target.style == .toggle }

    /// Current shortcut for this target (assistant may be unset).
    private var current: Hotkey? { settings.shortcut(for: target) }

    /// Optional shortcuts (assistant, stream) can be cleared back to
    /// disabled; the primary key can't be unset.
    private var isClearable: Bool { !(target.spec?.required ?? true) }

    private var buttonLabel: String {
        if recording { return "Recording…" }
        return current?.displayLabel ?? "Record"
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SliveTheme.rowFont)
                    .foregroundStyle(SliveTheme.textPrimary)
                caption
            }
            Spacer(minLength: 8)
            if isClearable && current != nil && !recording {
                Button {
                    clearShortcut()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(SliveTheme.textFaint)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
            Button {
                recording ? cancel() : startRecording()
            } label: {
                HStack(spacing: 6) {
                    if recording {
                        StatusDot(color: .white, pulses: true, size: 7)
                    }
                    Text(buttonLabel)
                        .font(SliveTheme.rowFont)
                }
                .frame(minWidth: 108)
            }
            .buttonStyle(.borderedProminent)
            .tint(recording ? SliveTheme.warn : SliveTheme.accent)
        }
        // Switching pages (or closing Settings) mid-recording must not leave
        // the monitor behind — it swallows every key the app sees.
        .onDisappear { if recording { cancel() } }
    }

    /// Under the title: the prompt (or why a press was refused) while
    /// recording; else this row's conflicts; else the subtitle.
    @ViewBuilder private var caption: some View {
        if recording {
            if let refusal {
                captionText(refusal, warn: true)
            } else {
                captionText(supportsDoubleTap ? "Press a key. Double-tap for ×2. Esc cancels."
                                              : "Press a key or combo. Esc cancels.", warn: false)
            }
        } else {
            let warnings = Self.warnings(for: target, settings: settings, capabilities: capabilities)
            if !warnings.isEmpty {
                ForEach(warnings, id: \.self) { captionText($0, warn: true) }
            } else if !subtitle.isEmpty {
                captionText(subtitle, warn: false)
            }
        }
    }

    private func captionText(_ text: String, warn: Bool) -> some View {
        Text(text)
            .font(SliveTheme.captionFont)
            .foregroundStyle(warn ? SliveTheme.warnText : SliveTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Recording

    private func startRecording() {
        recording = true
        refusal = nil
        capture.onOutcome = { apply($0) }
        capture.start()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            return nil   // swallow everything while recording
        }
    }

    private func cancel() {
        recording = false
        refusal = nil
        capture.stop()
        capture.onOutcome = { _ in }   // it held this view: no cycle left behind
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    /// Save, refuse (and keep listening), or keep waiting.
    private func apply(_ outcome: KeyOutcome) {
        switch outcome {
        case .cancel: cancel()
        case .ignore: break
        case .refuse(let reason): refusal = reason
        case .commit(let hotkey):
            let bindings = HotkeyBinding.effective(from: settings, capabilities: capabilities)
            if let reason = ShortcutConflicts.refusal(for: hotkey, on: target, among: bindings) {
                refusal = reason   // nothing saved
                return
            }
            settings.setShortcut(hotkey, for: target)
            cancel()
        }
    }

    private func clearShortcut() {
        guard isClearable else { return }
        settings.setShortcut(nil, for: target)
    }

    private func handle(_ event: NSEvent) {
        let mods = UInt64(event.modifierFlags.rawValue) & Hotkey.modifierMask
        switch event.type {
        case .flagsChanged:
            capture.flagsChanged(mods, style: target.style)
        case .keyDown:
            capture.keyDown(keyCode: event.keyCode, modifiers: mods,
                            characters: event.charactersIgnoringModifiers)
        default:
            break
        }
    }

    // MARK: - Pure recording rules (self-tested against the monitor)

    enum KeyOutcome: Equatable {
        case cancel
        /// Keep waiting (a bare typing key would hijack that key).
        case ignore
        /// Keep waiting, and say why this can't be a shortcut.
        case refuse(String)
        case commit(Hotkey)
    }

    static let shiftTypesText = "⇧ + this key types text."
    static func firesWhileTyping(_ symbol: String) -> String { "\(symbol) alone fires while you type." }
    static func systemShortcut(_ label: String) -> String { "\(label) is a system shortcut." }

    /// Keys that move the caret or edit text. Saved bare, the monitor would
    /// swallow them in every app (arrows and Home/End carry fn implicitly).
    static let editingKeys: Set<UInt16> = [
        36, 76, 48, 51, 49, 117,      // Return Enter Tab Delete Space ⌦
        123, 124, 125, 126,           // arrows
        115, 119, 116, 121,           // Home End PgUp PgDn
    ]

    /// A shortcut macOS or every app already owns; saved, it would stop
    /// working everywhere. `character` (the menu shortcuts) matches by the
    /// layout's letter when the event has one, else by the US key position.
    struct SystemShortcut {
        let key: String
        let modifiers: UInt64
        let keyCode: UInt16
        var character: Character?
    }

    static let systemShortcuts: [SystemShortcut] = {
        let cmd = CGEventFlags.maskCommand.rawValue
        let shift = CGEventFlags.maskShift.rawValue
        let ctrl = CGEventFlags.maskControl.rawValue
        let menu: [(Character, UInt16)] = [("c", 8), ("v", 9), ("x", 7), ("z", 6), ("a", 0),
                                           ("q", 12), ("w", 13), ("h", 4), ("m", 46)]
        return menu.map { SystemShortcut(key: String($0.0).uppercased(), modifiers: cmd, keyCode: $0.1, character: $0.0) }
            + [SystemShortcut(key: "Tab", modifiers: cmd, keyCode: 48),
               SystemShortcut(key: "Space", modifiers: cmd, keyCode: 49),
               SystemShortcut(key: "Space", modifiers: ctrl, keyCode: 49),
               SystemShortcut(key: "3", modifiers: cmd | shift, keyCode: 20),
               SystemShortcut(key: "4", modifiers: cmd | shift, keyCode: 21),
               SystemShortcut(key: "5", modifiers: cmd | shift, keyCode: 23)]
    }()

    /// The system shortcut a press is, if any.
    static func systemShortcut(keyCode: UInt16, modifiers: UInt64, characters: String?) -> SystemShortcut? {
        let typed = characters?.lowercased()
        let letter = typed.flatMap { $0.count == 1 && $0.unicodeScalars.allSatisfy(\.isASCII) ? $0.first : nil }
        return systemShortcuts.first { s in
            guard s.modifiers == modifiers else { return false }
            if let c = s.character, let letter { return c == letter }
            return s.keyCode == keyCode
        }
    }

    /// A key pressed while recording, with the (masked) modifiers its event
    /// carried. Esc cancels; a bare editing key or a system shortcut is
    /// refused; another bare typing key is ignored; ⇧ + a typing key is
    /// refused (its capital or symbol could never be typed again); function
    /// keys and anything else with a modifier is recorded.
    static func keyDownOutcome(keyCode: UInt16, modifiers: UInt64, characters: String?) -> KeyOutcome {
        if keyCode == 53 { return .cancel }
        let pressed = Hotkey.implicitFnKeyCodes.contains(keyCode) ? modifiers & ~Hotkey.fnFlag : modifiers
        if pressed == 0, editingKeys.contains(keyCode), let name = Hotkey.keyName(keyCode) {
            return .refuse(firesWhileTyping(name))
        }
        if modifiers == 0 && !Hotkey.isSpecialKey(keyCode) { return .ignore }
        if modifiers == CGEventFlags.maskShift.rawValue && Hotkey.typesText(keyCode) {
            return .refuse(shiftTypesText)
        }
        if let s = systemShortcut(keyCode: keyCode, modifiers: modifiers, characters: characters) {
            return .refuse(systemShortcut(Hotkey.makeLabel(modifiers: s.modifiers, keyChar: s.key)))
        }
        let label = Hotkey.makeLabel(modifiers: modifiers, keyCode: keyCode, characters: characters)
        return .commit(Hotkey(modifiers: modifiers, keyCode: keyCode, label: label))
    }

    /// Modifiers pressed alone, once every one is released. A bare ⇧ or ⌘
    /// hold — or single-tap toggle — is refused: both are pressed constantly
    /// while typing, so it would fire mid-word (a single tap toggles on every
    /// capital). A double tap (⇧ ×2) is deliberate and allowed.
    static func modifierOutcome(_ modifiers: UInt64, taps: Int, style: BindingStyle) -> KeyOutcome {
        if style == .hold || taps < 2 {
            if modifiers == CGEventFlags.maskShift.rawValue { return .refuse(firesWhileTyping("⇧")) }
            if modifiers == CGEventFlags.maskCommand.rawValue { return .refuse(firesWhileTyping("⌘")) }
        }
        return .commit(modifierHotkey(modifiers, taps: style == .toggle ? taps : 1))
    }

    /// A modifier-only shortcut, once every modifier is released.
    static func modifierHotkey(_ modifiers: UInt64, taps: Int) -> Hotkey {
        let label = Hotkey.makeLabel(modifiers: modifiers, keyChar: nil) + (taps >= 2 ? " ×2" : "")
        return Hotkey(modifiers: modifiers, keyCode: nil, label: label, taps: taps)
    }

    /// A Settings row's warnings: its stored shortcut's conflicts with the
    /// other enabled shortcuts, one line per other shortcut (a clash before
    /// an overlap).
    static func warnings(for target: BindingSlot, settings: Settings, capabilities: Capabilities) -> [String] {
        let bindings = HotkeyBinding.effective(from: settings, capabilities: capabilities)
        guard let mine = bindings.first(where: { $0.slot == target }) else { return [] }
        let conflicts = ShortcutConflicts.check(mine, against: bindings)
        var lines: [String] = []
        var named: [BindingSlot] = []
        for c in conflicts.filter(\.isExact) + conflicts.filter({ !$0.isExact }) where !named.contains(c.other) {
            named.append(c.other)
            lines.append(c.message)
        }
        return lines
    }
}

/// The recorder's press handling, apart from the view so the ×2 wait runs
/// on a test clock. A toggle target's modifier tap waits a beat for a second
/// tap; only the latest tap's wait may commit, and never once recording ended.
@MainActor final class ShortcutCapture {
    private let scheduler: MainScheduler
    /// Receives each decided press (save, refuse, cancel).
    var onOutcome: (HotkeyRecorderView.KeyOutcome) -> Void = { _ in }
    private(set) var isRecording = false
    private var maxModifiers: UInt64 = 0
    private var pendingTapMods: UInt64 = 0
    private var commitWork: DispatchWorkItem?

    init(scheduler: MainScheduler = DispatchMainScheduler.shared) {
        self.scheduler = scheduler
    }

    func start() {
        stop()
        isRecording = true
    }

    func stop() {
        isRecording = false
        cancelPendingCommit()
        maxModifiers = 0
    }

    func flagsChanged(_ mods: UInt64, style: BindingStyle) {
        guard isRecording else { return }
        maxModifiers |= mods
        // All modifiers released with no key pressed → a modifier-only shortcut.
        guard mods == 0, maxModifiers != 0 else { return }
        let released = maxModifiers
        maxModifiers = 0
        guard style == .toggle else {
            onOutcome(HotkeyRecorderView.modifierOutcome(released, taps: 1, style: style))
            return
        }
        // Second tap of the same gesture inside the window → ×2.
        if pendingTapMods == released {
            cancelPendingCommit()
            onOutcome(HotkeyRecorderView.modifierOutcome(released, taps: 2, style: style))
            return
        }
        // A tap: hold the commit briefly for a second one. A different
        // modifier replaces an earlier tap's wait — left running, it refused
        // or saved after the user had moved on (even after Esc).
        cancelPendingCommit()
        pendingTapMods = released
        commitWork = scheduler.after(Hotkey.doubleTapInterval) { [weak self] in
            guard let self, self.isRecording, self.pendingTapMods == released else { return }
            self.pendingTapMods = 0
            self.commitWork = nil
            self.onOutcome(HotkeyRecorderView.modifierOutcome(released, taps: 1, style: style))
        }
    }

    func keyDown(keyCode: UInt16, modifiers: UInt64, characters: String?) {
        guard isRecording else { return }
        onOutcome(HotkeyRecorderView.keyDownOutcome(keyCode: keyCode, modifiers: modifiers, characters: characters))
    }

    private func cancelPendingCommit() {
        commitWork?.cancel()
        commitWork = nil
        pendingTapMods = 0
    }
}
