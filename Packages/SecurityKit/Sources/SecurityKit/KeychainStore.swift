import Foundation
import Security

/// Generic-password Keychain storage for endpoint URLs and tokens.
/// ThisDeviceOnly: secrets never ride iCloud Keychain sync — a homelab
/// URL/token configured on the Mac stays on the Mac.
public enum KeychainStore {
    public static let service = "com.rchaight.notetaker"

    @discardableResult
    public static func save(_ value: String, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return true } // empty = delete
        var attributes = base
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    public static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// One-time migration: moves a UserDefaults value into the Keychain.
    public static func migrateFromDefaults(key: String, account: String) -> String {
        if let existing = read(account: account) { return existing }
        let legacy = UserDefaults.standard.string(forKey: key) ?? ""
        if !legacy.isEmpty, save(legacy, account: account) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        return legacy
    }
}
