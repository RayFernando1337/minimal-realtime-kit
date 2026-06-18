//  SecretsResolver.swift
//  T0.2 — tiny BYO-key runtime resolver (NO real secrets in this file).
//
//  Filename note: this is deliberately NOT named `Secrets.swift` — the repo's .gitignore
//  defensively ignores any file named `Secrets.swift` (the conventional place people paste a
//  real key), so the safe resolver lives here under a distinct name and is committed normally.
//
//  A single place for later tiers to ask "what's the OpenAI key right now?" without caring
//  where it lives. Resolution order (first usable wins; nil => the UI prompts the user to
//  paste a key — the app never crashes and a clean clone compiles):
//    1. Keychain — set by the paste-your-key screen (KeyEntryView). Best for shipping.
//    2. Generated Info.plist value from Config/Secrets.xcconfig via INFOPLIST_KEY_OPENAI_API_KEY.
//    3. Process environment (e.g. SIMCTL_CHILD_OPENAI_API_KEY on the simulator) — handy for dev.
//
//  `nonisolated` so the Tier-1 realtime actor can resolve synchronously. The "<<" / "REPLACE_"
//  guard rejects un-filled placeholders so a template value never reads as a real key.

import Foundation

nonisolated enum Secrets {
    private static let openAIKeyName = "OPENAI_API_KEY"

    /// The user's OpenAI key, or nil when unset. Prefer the credential seam
    /// (`PastedKeyProvider`) in production; this resolver is the convenient dev path.
    static var openAIAPIKey: String? {
        // 1) Keychain (paste-key screen) — wired to the real KeychainStore.
        if let value = KeychainStore.load(), isUsable(value) { return value }

        // 2) Generated Info.plist value (from Config/Secrets.xcconfig).
        if let value = Bundle.main.object(forInfoDictionaryKey: openAIKeyName) as? String, isUsable(value) {
            return value
        }

        // 3) Process environment.
        if let value = ProcessInfo.processInfo.environment[openAIKeyName], isUsable(value) {
            return value
        }

        return nil
    }

    /// Reject empty/whitespace-only strings and un-filled "<<…>>" / "REPLACE_…" placeholders.
    private static func isUsable(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasPrefix("<<") && !trimmed.hasPrefix("REPLACE_")
    }
}
