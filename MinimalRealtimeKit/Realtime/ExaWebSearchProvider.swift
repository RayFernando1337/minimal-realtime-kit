//  ExaWebSearchProvider.swift
//  Fills the `web_search` provider seam with a real, BRING-YOUR-OWN-KEY EXA implementation.
//
//  The source Pebbles app reached EXA through an AIProxy partial key (a shipped secret we
//  CAN'T publish). This kit is BYO-direct instead: the user pastes their OWN EXA key in the
//  "Web search (optional)" section of the key screen, it lives ONLY in the Keychain, and this
//  provider calls EXA directly with it. No key ever ships (SPEC N1).
//
//  Why direct + "instant": EXA's `type: "instant"` is its sub-200ms mode "optimized for
//  real-time apps like chat/voice" — the fast path that keeps the deferred tool turn snappy.
//  (https://exa.ai/docs/reference/search — `fast` is a fine fallback; never a `deep*` type.)
//
//  CONTRACT (mirrors the seam in ToolCatalog.swift): `search(query:)` MUST NEVER throw and MUST
//  NEVER log the key. Every outcome is a compact JSON envelope the model can read aloud:
//    • no/empty key  → {"status":"unconfigured","message":…}   (NO network hop)
//    • success       → {"query":…,"results":[{"title","url","snippet"}, …]}
//    • any failure   → {"status":"error","message":"Couldn't search right now."}
//
//  Concurrency: `nonisolated` + `Sendable` so the @AIProxyActor can `await` it from its own
//  isolation domain (matches `UnconfiguredWebSearchProvider`). URLSession does the network hop
//  off the realtime receiver loop (the dispatch side already defers web_search — SPEC N2).

import Foundation

/// A bring-your-own-key EXA web-search provider. Reads the EXA key FRESH from the Keychain on
/// every call (so saving/forgetting a key takes effect immediately), then calls EXA directly.
nonisolated struct ExaWebSearchProvider: WebSearchProvider {

    /// EXA's direct search endpoint — a PUBLIC URL, not a secret (fine to ship in source).
    private static let endpointString = "https://api.exa.ai/search"
    /// Cap candidates so "give me options" queries have enough to choose from without a wall of JSON.
    private static let maxResults = 8
    /// Keep each snippet short + speakable instead of a full article.
    private static let maxSnippetLength = 280

    func search(query: String) async -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return RealtimeManager.jsonString(["status": "error", "message": "Empty search query."])
        }

        // N1: resolve the BYO EXA key FRESH from the Keychain each call. Missing/empty → a graceful
        // "unconfigured" envelope and NO network hop. The key is read into a local, never logged.
        guard let key = KeychainStore.load(account: KeychainStore.exaKeyAccount),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return RealtimeManager.jsonString([
                "status": "unconfigured",
                "message": "Web search needs an EXA key — add one in settings (dashboard.exa.ai/api-keys)."
            ])
        }

        guard let endpoint = URL(string: Self.endpointString) else { return Self.errorEnvelope() }

        do {
            let body = ExaSearchRequest(
                query: trimmed,
                type: "instant",
                numResults: Self.maxResults,
                contents: .init(highlights: true)
            )
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // The user's own EXA key — header only, on a direct TLS call. Never logged (N1).
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.httpBody = try JSONEncoder().encode(body)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return Self.errorEnvelope()
            }

            // Map EXA's results → the compact {title, url, snippet} envelope the model reads.
            let decoded = try JSONDecoder().decode(ExaSearchResponse.self, from: data)
            let results: [[String: String]] = (decoded.results ?? []).prefix(Self.maxResults).map { result in
                [
                    "title": result.title ?? "",
                    "url": result.url ?? "",
                    "snippet": Self.snippet(highlights: result.highlights, text: result.text)
                ]
            }
            return RealtimeManager.jsonString(["query": trimmed, "results": results])
        } catch {
            // Any failure (encode/network/decode) → ONE safe envelope. Never surface the error
            // detail (it could echo the key or the request) — the model just says it couldn't look.
            return Self.errorEnvelope()
        }
    }

    /// The single safe failure envelope. Never leaks the key, the query detail, or the error.
    private static func errorEnvelope() -> String {
        RealtimeManager.jsonString(["status": "error", "message": "Couldn't search right now."])
    }

    /// Pick the first non-empty highlight (or fall back to body text), flatten newlines, and cap
    /// the length so the model gets a short, speakable snippet instead of a full article.
    private static func snippet(highlights: [String]?, text: String?) -> String {
        let raw = highlights?.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ?? text
            ?? ""
        let cleaned = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > maxSnippetLength else { return cleaned }
        return cleaned.prefix(maxSnippetLength).trimmingCharacters(in: .whitespacesAndNewlines) + "\u{2026}"
    }

    // MARK: - Lean Codable shapes
    // Request mirrors EXA's `/search` body; response fields are ALL OPTIONAL so a partial or
    // unexpected payload decodes to nils (→ graceful envelope) instead of throwing.

    /// Request body for EXA's `/search` endpoint.
    private struct ExaSearchRequest: Encodable {
        let query: String
        let type: String
        let numResults: Int
        let contents: Contents

        struct Contents: Encodable {
            let highlights: Bool
        }
    }

    /// The subset of EXA's `/search` response we use.
    private struct ExaSearchResponse: Decodable {
        let results: [Result]?

        struct Result: Decodable {
            let title: String?
            let url: String?
            let highlights: [String]?
            let text: String?
        }
    }
}
