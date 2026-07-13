import Foundation
import Security

/// Tiny wrapper over the macOS Keychain for storing provider API keys.
///
/// Keys never touch UserDefaults (a plain plist that any process reading the
/// app's container could see); they live in the login keychain as generic
/// passwords scoped to this app's service name.
enum KeychainStore {
    private static let service = "com.flowy.overlay.apikeys"

    /// Store (or clear, when `value` is empty/nil) the secret for `account`.
    static func set(_ value: String?, for account: String) {
        // Always delete first so we never hit a duplicate-item error and so an
        // empty value simply removes the entry.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = query
        add[kSecValueData as String] = data
        // Available whenever the Mac is unlocked; not synced to iCloud.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Read the secret for `account`, or nil if none is stored.
    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
