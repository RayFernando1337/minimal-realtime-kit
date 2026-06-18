// KeychainStore.swift
// Minimal, dependency-free Keychain wrapper for a *user-pasted* OpenAI API key.
//
// WHY KEYCHAIN (not UserDefaults / @AppStorage / a file): the Keychain is hardware-
// encrypted and access-controlled; UserDefaults is plaintext at rest. A pasted API key
// is a secret, so it MUST live here.
//   - Apple: "Storing Keys in the Keychain"
//     https://developer.apple.com/documentation/security/storing-keys-in-the-keychain
//   - kSecAttrAccessibleWhenUnlockedThisDeviceOnly (sensitive, never migrates via backup)
//     https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly
//
// NOTE: This stores the user's OWN key on the user's OWN device. That is acceptable for a
// BYO-key app. It is NOT a way to ship the author's key. For a higher bar, mint short-lived
// ephemeral tokens from a tiny backend instead (see EphemeralTokenClient.swift).

import Foundation
import Security

enum KeychainStore {
    /// Logical account name for the stored secret. Service is derived from the bundle id.
    static let account = "openai_api_key"
    static var service: String { Bundle.main.bundleIdentifier ?? "minimal-realtime-kit" }

    enum KeychainError: Error { case unexpectedStatus(OSStatus) }

    /// Insert or overwrite the secret. Uses delete-then-add so re-pasting always wins.
    static func save(_ secret: String) throws {
        let data = Data(secret.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary) // ignore errSecItemNotFound

        var add = base
        add[kSecValueData as String] = data
        // Sensitive + device-only: not exported in iCloud/iTunes backups.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    /// Read the secret, or nil if none stored.
    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Remove the stored secret (e.g. a "Forget my key" button — always offer this).
    @discardableResult
    static func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
