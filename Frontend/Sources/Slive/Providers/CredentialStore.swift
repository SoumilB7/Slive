import Foundation

/// Where secrets are kept. The Keychain in the app; an in-memory stand-in in
/// the self-test, so credential rules are checked without touching the
/// user's keychain.
protocol SecretStore {
    func get(_ account: String) -> String?
    /// Store, or clear when `value` is empty/nil. Returns whether the store now
    /// holds exactly that.
    @discardableResult func set(_ value: String?, for account: String) -> Bool
}

struct KeychainSecrets: SecretStore {
    func get(_ account: String) -> String? { KeychainStore.get(account) }
    @discardableResult func set(_ value: String?, for account: String) -> Bool {
        KeychainStore.set(value, for: account)
    }
}

/// The single owner of provider API keys and the Hugging Face token. Keys
/// live only in the Keychain, never in UserDefaults; the account names are
/// fixed (`provider.<raw value>`, `provider.huggingface`) so keys saved by
/// earlier builds keep working.
final class CredentialStore {
    static let shared = CredentialStore(secrets: KeychainSecrets())

    /// Keychain account for the Hugging Face access token used by the
    /// Local provider (downloads models to run on this Mac).
    static let hfAccount = "provider.huggingface"

    /// Keychain account name for a provider's API key.
    static func account(for provider: AssistantProvider) -> String {
        "provider.\(provider.rawValue)"
    }

    private let secrets: SecretStore

    init(secrets: SecretStore) {
        self.secrets = secrets
    }

    /// Read a provider's stored API key ("" if none). Trimmed on read as
    /// well as write: a value stored by an earlier build (before `setAPIKey`
    /// trimmed) can still carry a trailing newline, which would otherwise reach
    /// the HTTP layer as an illegal `Authorization` header value.
    func apiKey(for provider: AssistantProvider) -> String {
        (secrets.get(Self.account(for: provider)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Store (or clear, when empty) a provider's API key. Trimmed so a stray
    /// newline/space (common when pasting) can't produce an illegal HTTP header.
    @discardableResult
    func setAPIKey(_ key: String, for provider: AssistantProvider) -> Bool {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return secrets.set(clean, for: Self.account(for: provider))
    }

    func hasKey(_ provider: AssistantProvider) -> Bool {
        !apiKey(for: provider).isEmpty
    }

    var huggingFaceToken: String {
        secrets.get(Self.hfAccount) ?? ""
    }

    @discardableResult
    func setHuggingFaceToken(_ value: String) -> Bool {
        secrets.set(value.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.hfAccount)
    }
}
