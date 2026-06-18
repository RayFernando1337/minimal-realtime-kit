// EphemeralTokenClient.swift
// iOS side of the OpenAI-recommended pattern: fetch a short-lived ephemeral client secret
// from a tiny backend, then use it as the bearer for the realtime WebSocket/WebRTC connection.
//
// The device NEVER sees the standing OpenAI key — only an "ek_..." token that expires
// (default 10 min, configurable 10s–7200s on the backend).
//
// Matching backends: mint-token.worker.js (Cloudflare) and mint-token.node.js (Node/Express).
// API ref (GA): POST https://api.openai.com/v1/realtime/client_secrets
//   https://developers.openai.com/api/reference/resources/realtime/subresources/client_secrets/methods/create/

import Foundation

struct EphemeralToken {
    let value: String        // "ek_..." — pass as Authorization: Bearer <value>
    let expiresAt: Date?
}

struct EphemeralTokenClient {
    enum TokenError: Error { case badResponse(Int), missingValue }

    /// Calls YOUR backend's /token endpoint. The backend holds the real key and calls OpenAI.
    /// Expected JSON (pass-through of OpenAI's GA response): { "value": "ek_...", "expires_at": 173... }
    func fetchToken(from endpoint: URL) async throws -> EphemeralToken {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET" // or POST; match your backend
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TokenError.badResponse((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }

        // GA: the ephemeral secret is at top-level `value` (NOT `client_secret.value`).
        struct Payload: Decodable { let value: String?; let expires_at: Double? }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let value = payload.value else { throw TokenError.missingValue }

        let expiry = payload.expires_at.map { Date(timeIntervalSince1970: $0) }
        return EphemeralToken(value: value, expiresAt: expiry)
    }
}
