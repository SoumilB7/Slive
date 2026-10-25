import Foundation
import Security

/// Tiny wrapper over the macOS Keychain for storing provider API keys.
///
/// Keys never touch UserDefaults (a plain plist that any process reading the
/// app's container could see); they live in the login keychain as generic
/// passwords scoped to this app's service name.
enum KeychainStore {
    private static let service = "com.slive.app.apikeys"

    /// Store (or clear, when `value` is empty/nil) the secret for `account`.
    /// Returns whether the keychain now holds exactly that (cleared = no item).
    @discardableResult
    static func set(_ value: String?, for account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        // Update in place, add only when absent. Delete-then-add (the old
        // path, run per keystroke) left NO key behind whenever the add failed
        // — and the failure was silently ignored.
        var status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            // Available whenever the Mac is unlocked; not synced to iCloud.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            NSLog("Slive: keychain write for \(account) failed (\(status))")
        }
        return status == errSecSuccess
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
