//  KeychainStore.swift
//  T0.2 — Key plumbing (paste-key → Keychain)
//
//  Minimal, dependency-free Keychain wrapper for a *user-pasted* OpenAI API key.
//
//  WHY KEYCHAIN (not UserDefaults / @AppStorage / a file): the Keychain is hardware-
//  encrypted and access-controlled; UserDefaults is plaintext at rest. A pasted API key
//  is a secret, so it MUST live here.
//    - Apple: "Storing Keys in the Keychain"
//      https://developer.apple.com/documentation/security/storing-keys-in-the-keychain
//    - kSecAttrAccessibleWhenUnlockedThisDeviceOnly (sensitive; never migrates via backup)
//      https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly
//
//  NOTE: This stores the user's OWN key on the user's OWN device — acceptable for a
//  BYO-key app. It is NOT a way to ship the author's key (invariant N1). For a higher
//  bar, mint short-lived ephemeral tokens from a tiny backend instead (a Tier-5 add).
//
//  Concurrency: `nonisolated` so the realtime layer (a global actor, added in Tier 1)
//  can read/write synchronously from any isolation domain. The Security C APIs used here
//  are thread-safe and synchronous.

import Foundation
import Security

nonisolated enum KeychainStore {
    /// Logical account for the user's pasted OpenAI key. The store is keyed by
    /// (service, account), so additional secrets can be added later via a distinct account.
    static let openAIKeyAccount = "openai_api_key"

    /// Service scopes the items to this app. Derived from the bundle id; the fallback is a
    /// neutral, non-secret placeholder (never a real bundle prefix).
    static var service: String { Bundle.main.bundleIdentifier ?? "com.example.MinimalRealtimeKit" }

    enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
    }

    /// Insert or overwrite a secret for `account`. Delete-then-add so re-pasting always wins.
    static func save(_ secret: String, account: String = openAIKeyAccount) throws {
        let data = Data(secret.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary) // errSecItemNotFound is fine — nothing to remove yet.

        var add = base
        add[kSecValueData as String] = data
        // Sensitive + device-only: not exported in iCloud/iTunes backups, readable only while unlocked.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    /// Read the secret for `account`, or nil if none is stored.
    static func load(account: String = openAIKeyAccount) -> String? {
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

    /// Whether a non-empty secret is stored for `account`. Does not expose the value.
    static func hasValue(account: String = openAIKeyAccount) -> Bool {
        guard let value = load(account: account) else { return false }
        return !value.isEmpty
    }

    /// Remove the stored secret for `account` (e.g. a "Forget key" button — always offer this).
    /// Returns true if the item is now absent (deleted, or was never there).
    @discardableResult
    static func delete(account: String = openAIKeyAccount) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

#if DEBUG
extension KeychainStore {
    /// Inert save→load→delete probe for manual verification (e.g. wired to a debug hook in a
    /// later tier). Uses a throwaway account so it never touches the real key, and returns a
    /// Bool — it NEVER prints or returns a secret value (invariant N1). Not called anywhere.
    static func debugRoundTripPasses() -> Bool {
        let probeAccount = "debug_roundtrip_probe"
        let sample = "round-trip-probe-value"
        defer { _ = delete(account: probeAccount) }
        do {
            try save(sample, account: probeAccount)
        } catch {
            return false
        }
        let readBack = load(account: probeAccount)
        let deleted = delete(account: probeAccount)
        return readBack == sample && deleted && load(account: probeAccount) == nil
    }
}
#endif
