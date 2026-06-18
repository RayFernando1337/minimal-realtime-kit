//
//  02-tool-dispatch.swift  —  REDACTED extract for minimal-realtime-kit
//
//  Source: OpenAIRealtimeSample/RealtimeManager.swift (lines cited inline).
//  The tool-calling engine + the one-response.create-per-turn discipline.
//
//  THE INVARIANT: exactly ONE `response.create` per tool turn. A bare
//  `conversation.item.create` (a functionCallOutput, a user item, or a system note)
//  NEVER triggers a model response on its own — ONLY `response.create` does. That's
//  what lets context-syncs and choice items be sent "for free".
//
//  TWO BRANCHES:
//   • INLINE   (fast/local tools): do the work, send functionCallOutput, optional
//              system context-sync note, then the ONE response.create — all inside
//              handleFunctionCall. Source: :801-818
//   • DEFERRED (slow/network tools): must NOT be awaited in the receiver loop (that
//              freezes audio). Kick off a detached Task → await the network → finish
//              through the SINGLE shared tail `completeDeferredToolTurn`, which sends
//              the ONE response.create. Source: :587-603, :829-841
//
//  The 4 (and only 4) response.create sites:
//   1. greeting                     (01-lifecycle.swift, :333)
//   2. sendUserChoice               (this file, :548)         — a NEW user turn
//   3. inline tool tail             (this file, :818)
//   4. completeDeferredToolTurn     (this file, :840)         — shared deferred tail
//

import AIProxy

extension RealtimeManager {

    // MARK: - Dispatch. Source: :583-821 (MVP-trimmed to web_search + surface_note + get_time)
    func handleFunctionCall(
        _ event: OpenAIRealtimeResponseFunctionCallArgumentsDoneEvent,
        session: OpenAIRealtimeSession
    ) async {
        // ── DEFERRED branch: SLOW tools return early via a detached Task. Source: :592-603 ──
        if event.name == "web_search" {
            let query = Self.decodeArguments(SearchArguments.self, from: event.arguments)?.query ?? ""
            Task { [weak self] in
                guard let self else { return }
                let output = await self.performWebSearch(query)          // network hop
                await self.completeDeferredToolTurn(callID: event.callID, output: output, on: session)
            }
            return   // ← critical: do NOT fall through to the inline send
        }

        // ── INLINE branch: FAST/local tools. Build `output`, optional context-sync note. ──
        let output: String
        var contextSyncNote: String?   // declarative role:"system" note, never read aloud. :656-660

        switch event.name {
        case "get_time":
            // Dead-simple local tool (no deps) — the canonical inline example.
            let now = ISO8601DateFormatter().string(from: Date())
            output = Self.jsonString(["now": now])

        case "surface_note":
            // Emit a UI card via the event bridge, immediately. Source: :696-710
            if let args = Self.decodeArguments(SurfaceNoteArguments.self, from: event.arguments),
               let content = Self.surfaceNoteContent(from: args) {
                self.emit(.note(content))
                output = Self.jsonString(["ok": true])
                // Keep the model's working context honest: connect-time prompt can't see a card
                // added mid-session, so declare it now (so the model can recall it). Source: :707
                contextSyncNote = Self.reminderSyncNote(for: content)
            } else {
                output = Self.jsonString(["ok": false, "reason": "no usable note"])
            }

        default:
            output = Self.jsonString(["error": "unknown tool"])
        }

        // 1) The tool result. A bare item.create — triggers NO response by itself. Source: :801-805
        await session.sendMessage(
            OpenAIRealtimeConversationItemCreate(
                item: .functionCallOutput(callID: event.callID, output: output)
            )
        )
        // 2) Optional system context-sync note (also bare — no response). Source: :809-815
        if let contextSyncNote {
            await session.sendMessage(
                OpenAIRealtimeConversationItemCreate(
                    item: .init(role: "system", text: contextSyncNote)
                )
            )
        }
        // 3) ── response.create SITE 3 of 4: INLINE TAIL ── Source: :817-818
        self.responseInFlight = true   // FIX C: set BEFORE the send
        await session.sendMessage(OpenAIRealtimeResponseCreate())
    }

    // MARK: - The SINGLE shared deferred tail. Source: :829-841
    // Every slow tool funnels here so the literal response.create count stays at 4.
    func completeDeferredToolTurn(callID: String, output: String, on session: OpenAIRealtimeSession) async {
        await session.sendMessage(
            OpenAIRealtimeConversationItemCreate(
                item: .functionCallOutput(callID: callID, output: output)
            )
        )
        // ── response.create SITE 4 of 4: DEFERRED TAIL ──
        self.responseInFlight = true
        await session.sendMessage(OpenAIRealtimeResponseCreate())
    }

    // MARK: - A choice tap is a NEW USER TURN (not a 2nd response on the show turn). Source: :533-549
    func sendUserChoice(_ text: String) async {
        guard let session = realtimeSession else { return }   // no live session → no-op
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // A bare user item never triggers a response on its own — safe even mid-turn.
        await session.sendMessage(
            OpenAIRealtimeConversationItemCreate(item: .init(role: "user", text: trimmed))
        )
        // Runtime turn-guard: if a response is already in flight, the duplicate response.create
        // would be rejected by the server (→ .error). The pick rides the next free turn. Source: :545
        guard !responseInFlight else { return }
        // ── response.create SITE 2 of 4: sendUserChoice ──
        self.responseInFlight = true   // FIX C
        await session.sendMessage(OpenAIRealtimeResponseCreate())
    }

    // MARK: - Context nudge: a role:"system" item with NO response.create. Source: :559-567
    // Use for LOCAL state changes (e.g. the user swiped a card away) the model should know about
    // on its next turn. Adds ZERO response.create sites — the count stays 4.
    func sendContextUpdate(_ systemText: String) async {
        guard let session = realtimeSession else { return }
        let trimmed = systemText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await session.sendMessage(
            OpenAIRealtimeConversationItemCreate(item: .init(role: "system", text: trimmed))
        )
        // NO response.create here.
    }
}

//
//  ─────────────────────────────────────────────────────────────────────────────
//  HOW TO ADD A TOOL  (recipe)
//  ─────────────────────────────────────────────────────────────────────────────
//  1. Define a Decodable args struct with OPTIONAL fields (so a malformed payload
//     decodes to a partial/nil instead of throwing). See SearchArguments etc., :991-1038.
//  2. Add a JSON-Schema dictionary `[String: AIProxyJSONValue]` (04-tool-schemas.swift).
//  3. Append `.function(.init(name:description:parameters:))` to `agentTools` (:1338-1431).
//  4. Handle it in handleFunctionCall:
//        • FAST/local tool → add a `case` in the switch; set `output`, optionally
//          `contextSyncNote`; it falls through to the SINGLE shared inline send.
//        • SLOW/network tool → handle it at the TOP with `Task { … await
//          completeDeferredToolTurn(…) }` then `return`. Add NO response.create yourself.
//  5. (If the tool changes state the prompt described at connect, add a declarative
//     `contextSyncNote` so the model's working set stays honest.)
//  6. Update the system instructions so the model knows when to call it.
//
//  GOLDEN RULE: never add a `response.create` to a tool turn. Build every new tool on
//  the inline fall-through or the shared deferred tail.
//

// MARK: - web_search fulfillment (Exa via a SECOND, separate proxy service). Source: :859-917
extension RealtimeManager {
    func performWebSearch(_ query: String) async -> String {
        // ⬇️ A SEPARATE proxy service from the OpenAI one. Source: :862-863 (REDACTED)
        let exaAIProxyPartialKey = "<<PASTE_YOUR_OWN>>"
        let exaAIProxyServiceURL = "<<PASTE_YOUR_OWN>>"

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Self.jsonString(["error": "empty query"]) }
        guard exaAIProxyPartialKey != "<<PASTE_YOUR_OWN>>" else {
            return Self.jsonString(["error": "web search not configured"])  // never crash
        }
        do {
            let requestBody = ExaSearchRequest(
                query: trimmed, type: "instant", numResults: 8, contents: .init(highlights: true)
            )
            // Generic proxied request — the real Exa Bearer key is injected server-side. :889-896
            let request = try await AIProxy.request(
                partialKey: exaAIProxyPartialKey,
                serviceURL: exaAIProxyServiceURL,
                proxyPath: "/search",
                body: try JSONEncoder().encode(requestBody),
                verb: .post,
                headers: ["content-type": "application/json"]
            )
            let (data, response) = try await AIProxy.session().data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return Self.jsonString(["error": "search failed"])
            }
            let decoded = try JSONDecoder().decode(ExaSearchResponse.self, from: data)
            let results: [[String: String]] = (decoded.results ?? []).prefix(8).map {
                ["title": $0.title ?? "", "url": $0.url ?? "",
                 "snippet": Self.snippet(highlights: $0.highlights, text: $0.text)]
            }
            return Self.jsonString(["query": trimmed, "results": results])
        } catch {
            return Self.jsonString(["error": "search failed", "detail": "\(error.localizedDescription)"])
        }
    }
}
