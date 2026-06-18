// RealtimeCredentialProvider.swift
// The seam that lets the SAME realtime client run in BOTH key modes.
//
// The realtime transport (WebSocket or WebRTC) only needs one thing: a bearer credential
// string to authenticate the connection. Hide *where it came from* behind this protocol so
// you can ship paste-key today and add ephemeral tokens later WITHOUT touching the client.
//
//   - Paste-key  -> the string is the user's own sk-... key (lives in Keychain, on device).
//   - Ephemeral  -> the string is a short-lived ek_... client secret minted by a tiny backend
//                   (the OpenAI-recommended pattern). The standing key never reaches the device.
//
// Either way the client does: connect with Authorization: Bearer <credential>.

import Foundation

/// A bearer credential plus when it stops being valid.
struct RealtimeCredential {
    let bearer: String        // "sk-..." (paste) or "ek_..." (ephemeral)
    let expiresAt: Date?      // nil for a paste-key; ~10 min out for an ephemeral token
}

protocol RealtimeCredentialProvider {
    /// Return a credential usable right now. Implementations may cache/refresh.
    func credential() async throws -> RealtimeCredential
}

// MARK: - Mode A: paste-your-own-key (simplest; key on device)

/// Reads the user's pasted key from the Keychain. No network, no backend.
struct PastedKeyProvider: RealtimeCredentialProvider {
    enum ProviderError: Error { case noKeyStored }

    func credential() async throws -> RealtimeCredential {
        guard let key = KeychainStore.load() else { throw ProviderError.noKeyStored }
        return RealtimeCredential(bearer: key, expiresAt: nil)
    }
}

// MARK: - Mode B: ephemeral token from the user's own backend (most correct)

/// Fetches a short-lived ephemeral token from a backend the *user* runs (URL is BYO-config,
/// not a secret). See EphemeralTokenClient.swift for the actual fetch + the backend snippets.
struct EphemeralTokenProvider: RealtimeCredentialProvider {
    let tokenEndpoint: URL          // e.g. https://<user-worker>.workers.dev/token
    private let client = EphemeralTokenClient()

    func credential() async throws -> RealtimeCredential {
        let token = try await client.fetchToken(from: tokenEndpoint)
        return RealtimeCredential(bearer: token.value, expiresAt: token.expiresAt)
    }
}
