//  RealtimeCredentialProvider.swift
//  T0.2 — the credential seam that lets the SAME realtime client run in multiple key modes.
//
//  The realtime transport (WebSocket / WebRTC, added in Tier 1) only needs one thing: a
//  credential string to authenticate the connection (used as `Authorization: <scheme> …`).
//  Hide *where it came from* behind this protocol so v1 ships paste-key today and ephemeral
//  tokens can be added later WITHOUT touching the client.
//
//    - Paste-key (v1, this file): the string is the user's own key, stored in the Keychain
//      on-device by the "Enter your OpenAI API key" screen (see KeyEntryView.swift).
//
//  Concurrency: the seam is `nonisolated` + `Sendable` so the Tier-1 realtime actor can hold
//  a provider and `await` a credential from its own isolation domain.

import Foundation

/// A credential string plus when it stops being valid.
nonisolated struct RealtimeCredential: Sendable, Equatable {
    /// The user's pasted key (paste-key mode). For an ephemeral token it would be the minted
    /// short-lived secret instead — same field, different source.
    let token: String
    /// nil for a paste-key (no expiry); a future date for an ephemeral token.
    let expiresAt: Date?

    init(token: String, expiresAt: Date? = nil) {
        self.token = token
        self.expiresAt = expiresAt
    }
}

/// Returns a credential usable right now. Implementations may cache/refresh.
nonisolated protocol RealtimeCredentialProvider: Sendable {
    func credential() async throws -> RealtimeCredential
}

// MARK: - v1: paste-your-own-key (simplest; key on device)

/// Reads the user's pasted key from the Keychain. No network, no backend.
nonisolated struct PastedKeyProvider: RealtimeCredentialProvider {
    enum ProviderError: Error, Equatable {
        case noKeyStored
    }

    func credential() async throws -> RealtimeCredential {
        guard let key = KeychainStore.load(), !key.isEmpty else {
            throw ProviderError.noKeyStored
        }
        return RealtimeCredential(token: key, expiresAt: nil)
    }
}

// Mode B (ephemeral `ek_…` token from a tiny user-run backend) is a Tier-5 add that slots in
// behind this same protocol as an `EphemeralTokenProvider` — no client changes required.
