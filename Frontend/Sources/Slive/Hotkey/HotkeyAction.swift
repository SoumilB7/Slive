import Foundation

/// Which behaviour a shortcut triggers. Declaration order is match priority:
/// when held modifiers match no single shortcut exactly, the first action
/// whose modifiers are all held wins (plain dictation dominates).
///
/// Adding an action:
/// 1. a case here and its `ActionSpec` (below) — keys, defaults, cue,
///    queue rule, required capability;
/// 2. its handler in the AppDelegate's start/stop/toggle flow.
/// Settings storage, the monitor's match tables, the recorder view and the
/// activation cue all follow from the spec. (Named Settings accessors like
/// `streamHotkey` exist only for older call sites; new code uses
/// `Settings.shortcut(for:)`.)
enum HotkeyAction: CaseIterable {
    case dictate   // transcribe speech and type/insert it
    case assist    // transcribe speech, send to an LLM, show the answer
    case stream    // live-transcribe speech and type it into the field as you talk

    /// Position in the match order (0 = highest).
    var priority: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    var spec: ActionSpec {
        switch self {
        case .dictate: return .dictate
        case .assist:  return .assist
        case .stream:  return .stream
        }
    }
}

/// Hold to talk (key-up ends it) or tap to start / tap again to stop.
enum BindingStyle: Hashable {
    case hold
    case toggle
}

/// One recordable shortcut: an action in one style.
struct BindingSlot: Hashable {
    let action: HotkeyAction
    let style: BindingStyle

    static let dictation = BindingSlot(action: .dictate, style: .hold)
    static let dictationToggle = BindingSlot(action: .dictate, style: .toggle)
    static let assistant = BindingSlot(action: .assist, style: .hold)
    static let stream = BindingSlot(action: .stream, style: .hold)
    static let streamToggle = BindingSlot(action: .stream, style: .toggle)

    var spec: SlotSpec? {
        style == .hold ? action.spec.hold : action.spec.toggle
    }
}

/// Where one slot's shortcut persists, and its fresh-install value.
struct SlotSpec {
    /// The shortcut, as Hotkey JSON.
    let key: String
    /// Its on/off switch (default on); nil = always on while bound.
    let switchKey: String?
    let defaultHotkey: Hotkey?
    /// Can't be cleared (hold-to-dictate): unreadable data falls back to the
    /// default instead of reading as "cleared".
    var required = false

    /// Never set → the default; set → the stored shortcut; cleared → nil.
    /// "Cleared" was written two ways over time — empty data and a removed
    /// key — and is now always empty data, which (like any undecodable
    /// value) reads as nil. A removed key reads as never set, which only
    /// matters for slots whose default isn't nil, and those always wrote
    /// empty data.
    func readShortcut(from store: KeyValueStore) -> Hotkey? {
        guard let data = store.data(forKey: key) else { return defaultHotkey }
        let decoded = try? JSONDecoder().decode(Hotkey.self, from: data)
        return required ? (decoded ?? defaultHotkey) : decoded
    }

    /// Cleared ≠ never set: a cleared slot stores empty data.
    func writeShortcut(_ hotkey: Hotkey?, to store: KeyValueStore) {
        guard let hotkey else { store.set(Data(), forKey: key); return }
        if let data = try? JSONEncoder().encode(hotkey) { store.set(data, forKey: key) }
    }
}

/// Everything the app needs to know about one action, in one place.
struct ActionSpec {
    let action: HotkeyAction
    /// User-facing name.
    let name: String
    let hold: SlotSpec?
    let toggle: SlotSpec?
    /// The sound when it goes live (FeedbackPlayer).
    let cue: ActivationCue
    /// Joins the DictationQueue even with the model ready and nobody waiting
    /// — spoken words always type, in order. (An assistant request instead
    /// may be superseded by a newer hold or ✕.)
    let alwaysQueues: Bool
    /// The capability the action needs; nil = every edition.
    let requires: KeyPath<Capabilities, Bool>?

    /// Every action, in priority order.
    static let all: [ActionSpec] = HotkeyAction.allCases.map(\.spec)

    var slots: [BindingSlot] {
        [hold.map { _ in BindingSlot(action: action, style: .hold) },
         toggle.map { _ in BindingSlot(action: action, style: .toggle) }].compactMap { $0 }
    }

    func isAvailable(in capabilities: Capabilities) -> Bool {
        requires.map { capabilities[keyPath: $0] } ?? true
    }

    static let dictate = ActionSpec(
        action: .dictate, name: "Dictation",
        hold: SlotSpec(key: "hotkey", switchKey: "dictateHoldOn",
                       defaultHotkey: .fnDefault, required: true),
        toggle: SlotSpec(key: "dictateToggleHotkey", switchKey: "dictateToggleOn",
                         defaultHotkey: Settings.defaultDictateToggle),
        cue: .dhum, alwaysQueues: true, requires: nil)

    static let assist = ActionSpec(
        action: .assist, name: "Assistant",
        hold: SlotSpec(key: "assistantHotkey", switchKey: nil,
                       defaultHotkey: Settings.defaultAssistantHotkey),
        toggle: nil,
        cue: .deepDhum, alwaysQueues: false, requires: \.assistant)

    /// Live typing stays off until asked for (no default shortcuts).
    static let stream = ActionSpec(
        action: .stream, name: "Live typing",
        hold: SlotSpec(key: "streamHotkey", switchKey: "streamHoldOn", defaultHotkey: nil),
        toggle: SlotSpec(key: "streamToggleHotkey", switchKey: "streamToggleOn", defaultHotkey: nil),
        cue: .dhum, alwaysQueues: true, requires: nil)
}

/// One shortcut as the HotkeyMonitor sees it. It matches only while enabled
/// and set.
struct HotkeyBinding: Equatable {
    let action: HotkeyAction
    let style: BindingStyle
    var hotkey: Hotkey?
    var enabled: Bool

    var slot: BindingSlot { BindingSlot(action: action, style: style) }

    /// The bindings the monitor should match: Settings' list minus actions
    /// this build can't run.
    static func effective(from settings: Settings, capabilities: Capabilities) -> [HotkeyBinding] {
        settings.bindings.filter { $0.action.spec.isAvailable(in: capabilities) }
    }
}
