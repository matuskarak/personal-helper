import Security
import Foundation

/// API keys live here, not in UserDefaults — a paid user's OpenAI key must not sit in a
/// world-readable plist. Generic-password items keyed by the same account names the old
/// UserDefaults entries used, so migration is a straight copy.
enum KeychainStore {
    private static let service = "sk.matuskarak.osobny-pomocnik"

    static func string(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                AppLogger.log("[KeychainStore] ⚠️ čítanie '\(account)' zlyhalo: OSStatus \(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// nil or empty deletes the item.
    static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            AppLogger.log("[KeychainStore] ⚠️ zápis '\(account)' zlyhal: OSStatus \(status)")
        }
    }

    /// Reads the key from the Keychain; if absent, migrates a legacy plaintext UserDefaults
    /// value (write to Keychain, delete from defaults). Idempotent — the defaults entry is
    /// gone after the first successful pass.
    static func stringMigratingFromDefaults(account: String) -> String {
        if let existing = string(for: account) { return existing }
        guard let legacy = UserDefaults.standard.string(forKey: account), !legacy.isEmpty else { return "" }
        set(legacy, for: account)
        // Only drop the plaintext copy once the Keychain write verifiably stuck —
        // otherwise a broken Keychain would silently destroy the user's only key.
        if string(for: account) == legacy {
            UserDefaults.standard.removeObject(forKey: account)
            AppLogger.log("[KeychainStore] kľúč '\(account)' presunutý z UserDefaults do Keychain")
        }
        return legacy
    }
}
