import Combine
import Foundation

/// Where settings persist: `UserDefaults` in the app, `InMemoryStore` in the
/// self-tests (defaults and migrations checked without touching the real
/// domain). The method set is exactly UserDefaults' own accessors, so every
/// read keeps UserDefaults' coercions.
protocol KeyValueStore: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
    func string(forKey defaultName: String) -> String?
    func data(forKey defaultName: String) -> Data?
    func bool(forKey defaultName: String) -> Bool
    func integer(forKey defaultName: String) -> Int
    func double(forKey defaultName: String) -> Double
}

extension UserDefaults: KeyValueStore {}

/// A dictionary-backed store for tests.
final class InMemoryStore: KeyValueStore {
    private(set) var values: [String: Any]

    init(_ values: [String: Any] = [:]) { self.values = values }

    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
    func string(forKey key: String) -> String? { values[key] as? String }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func bool(forKey key: String) -> Bool { (values[key] as? NSNumber)?.boolValue ?? false }
    func integer(forKey key: String) -> Int { (values[key] as? NSNumber)?.intValue ?? 0 }
    func double(forKey key: String) -> Double { (values[key] as? NSNumber)?.doubleValue ?? 0 }
}

// MARK: - Value encodings

/// How a value type is read from and written to a store. `read` returns nil
/// when the key was never set (or holds something unreadable) — the
/// declaration's default applies then. Equatable so `@Stored` can drop a
/// write that changes nothing (see its setter).
protocol StorableSetting: Equatable {
    static func read(from store: KeyValueStore, key: String) -> Self?
    func write(to store: KeyValueStore, key: String)
    /// Writing `other` over `self` would change nothing.
    func isSame(as other: Self) -> Bool
}

extension StorableSetting {
    func isSame(as other: Self) -> Bool { self == other }
}

// Scalars read through `object(forKey:)`, so UserDefaults and InMemoryStore
// agree and a value of the wrong kind (a hand-edited plist, another build)
// reads as unset — the default — instead of UserDefaults' silent 0 / false /
// "5". A string that spells the value (`defaults write … key 0.7`) still counts.

extension Bool: StorableSetting {
    static func read(from store: KeyValueStore, key: String) -> Bool? {
        switch store.object(forKey: key) {
        case let number as NSNumber: return number.boolValue
        case let text as String:
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "yes", "true": return true
            case "no", "false": return false
            case let other: return Double(other).map { $0 != 0 }
            }
        default: return nil
        }
    }
    func write(to store: KeyValueStore, key: String) { store.set(self, forKey: key) }
}

extension Double: StorableSetting {
    /// NaN and ±infinity read as unset: the first `Int(value)` would trap.
    static func read(from store: KeyValueStore, key: String) -> Double? {
        let value: Double?
        switch store.object(forKey: key) {
        case let number as NSNumber: value = number.doubleValue
        case let text as String: value = Double(text.trimmingCharacters(in: .whitespaces))
        default: value = nil
        }
        return value.flatMap { $0.isFinite ? $0 : nil }
    }
    func write(to store: KeyValueStore, key: String) { store.set(self, forKey: key) }
    /// NaN over NaN is no change either: `==` alone would publish it on every write.
    func isSame(as other: Double) -> Bool { self == other || (isNaN && other.isNaN) }
}

extension Int: StorableSetting {
    static func read(from store: KeyValueStore, key: String) -> Int? {
        switch store.object(forKey: key) {
        case let number as NSNumber:
            let d = number.doubleValue
            return d.isFinite && abs(d) < 1e15 ? number.intValue : nil
        case let text as String: return Int(text.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
    func write(to store: KeyValueStore, key: String) { store.set(self, forKey: key) }
}

extension String: StorableSetting {
    static func read(from store: KeyValueStore, key: String) -> String? {
        store.object(forKey: key) as? String
    }
    func write(to store: KeyValueStore, key: String) { store.set(self, forKey: key) }
}

/// String-backed enums persist their raw value; an unknown one reads as unset.
extension StorableSetting where Self: RawRepresentable, RawValue == String {
    static func read(from store: KeyValueStore, key: String) -> Self? {
        (store.object(forKey: key) as? String).flatMap(Self.init(rawValue:))
    }
    func write(to store: KeyValueStore, key: String) { store.set(rawValue, forKey: key) }
}

/// Codable structs persist as JSON; undecodable data reads as unset.
protocol JSONSetting: StorableSetting, Codable {}

extension JSONSetting {
    static func read(from store: KeyValueStore, key: String) -> Self? {
        store.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }
    func write(to store: KeyValueStore, key: String) {
        if let data = try? JSONEncoder().encode(self) { store.set(data, forKey: key) }
    }
}

// MARK: - Declarations

/// One setting: its key, its fresh-install default, and an optional fix-up
/// applied to a STORED value (migrations, clamps) — never to the default.
struct Setting<Value: StorableSetting> {
    let key: String
    let defaultValue: Value
    var normalize: (Value) -> Value = { $0 }

    func read(from store: KeyValueStore) -> Value {
        Value.read(from: store, key: key).map(normalize) ?? defaultValue
    }
}

extension Setting where Value == Double {
    /// A slider's setting: a stored value outside the slider's range (a
    /// hand-edited plist) reads clamped into it — `Int(1e300)` in a label traps.
    init(key: String, defaultValue: Double, range: ClosedRange<Double>) {
        self.init(key: key, defaultValue: defaultValue,
                  normalize: { min(max($0, range.lowerBound), range.upperBound) })
    }
}

extension Setting where Value == String {
    /// A model pick: a blank stored id names no model, so it reads as the default.
    init(modelKey key: String, defaultValue: String) {
        self.init(key: key, defaultValue: defaultValue, normalize: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultValue : $0
        })
    }
}

/// What `Settings` gives `@Stored`: somewhere to persist, a will-change
/// signal for SwiftUI, and a sink for change events.
protocol StoredSettingsOwner: ObservableObject where ObjectWillChangePublisher == ObservableObjectPublisher {
    var store: KeyValueStore { get }
    func publish(_ change: SettingsChange)
}

/// Type-erased view of a `@Stored` property, so `Settings.init` can load
/// every declaration up front and the self-tests can list them.
protocol AnyStoredSetting {
    var key: String { get }
    func load(from store: KeyValueStore)
}

/// A persisted `Settings` property in ONE declaration — key, default,
/// optional change event:
///
///     @Stored("overlayOpacity", default: 0.4) var overlayOpacity: Double
///
/// Setting a new value sends `objectWillChange` (SwiftUI), writes the store,
/// then publishes `emits` synchronously; a `didSet` on the property still
/// runs after, for side effects. Setting the value it already holds does
/// none of the three (a `didSet` still runs): a view `body` that writes a
/// setting would otherwise re-run itself forever (the shape of the Nov 13
/// freeze). Values are loaded
/// once in `Settings.init`.
@propertyWrapper
struct Stored<Value: StorableSetting>: AnyStoredSetting {
    let setting: Setting<Value>
    let change: SettingsChange?
    /// Shared by every copy of the wrapper (Mirror hands out copies).
    private let box = Box()
    private final class Box { var value: Value? }

    init(_ key: String, default value: Value, emits change: SettingsChange? = nil) {
        self.init(Setting(key: key, defaultValue: value), emits: change)
    }

    init(_ setting: Setting<Value>, emits change: SettingsChange? = nil) {
        self.setting = setting
        self.change = change
    }

    var key: String { setting.key }

    func load(from store: KeyValueStore) { box.value = setting.read(from: store) }

    /// Only reachable through the enclosing-instance subscript below.
    var wrappedValue: Value {
        get { fatalError("@Stored is only usable on a StoredSettingsOwner") }
        set { fatalError("@Stored is only usable on a StoredSettingsOwner") }
    }

    static subscript<Owner: StoredSettingsOwner>(
        _enclosingInstance owner: Owner,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<Owner, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<Owner, Self>
    ) -> Value {
        get {
            let stored = owner[keyPath: storageKeyPath]
            if let value = stored.box.value { return value }
            let value = stored.setting.read(from: owner.store)
            stored.box.value = value
            return value
        }
        set {
            let stored = owner[keyPath: storageKeyPath]
            let current = stored.box.value ?? stored.setting.read(from: owner.store)
            if current.isSame(as: newValue) { return }
            owner.objectWillChange.send()
            stored.box.value = newValue
            newValue.write(to: owner.store, key: stored.setting.key)
            if let change = stored.change { owner.publish(change) }
        }
    }
}
