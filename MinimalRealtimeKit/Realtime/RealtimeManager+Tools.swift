//  RealtimeManager+Tools.swift
//  T2.1 — the tool-DISPATCH engine, on the @AIProxyActor (these methods touch the live
//  session + `responseInFlight`, so they're isolated; the pure catalog/helpers are in
//  ToolCatalog.swift).
//
//  THE INVARIANT (SPEC N2): exactly ONE `response.create` per tool turn. A
//  bare `conversation.item.create` (a function_call_output, a role:"user" item, or a
//  role:"system" note) triggers NO model response on its own — ONLY `response.create` does.
//  That's what lets tool outputs, context-syncs, and choice items be appended "for free".
//
//  The 4 (and ONLY 4) response.create sites — reference by symbol/branch, not line number:
//    1. greeting                  → RealtimeManager.swift, `.sessionUpdated` case
//    2. sendUserChoice            → this file (a card tap = a NEW user turn)
//    3. inline tail               → this file, end of handleFunctionCall (fast/local tools)
//    4. completeDeferredToolTurn  → this file (the ONE tail every slow/network tool funnels through)
//
//  TWO BRANCHES in handleFunctionCall:
//    • DEFERRED (slow/network, e.g. web_search): MUST NOT be awaited in the receiver loop —
//      that would freeze audio. Kick off a Task, await the network, then finish through the
//      shared deferred tail. Adds NO response.create of its own.
//    • INLINE (fast/local, e.g. get_time): do the work, send the output, then the single
//      inline response.create.

import AIProxy
import Foundation

extension RealtimeManager {

    // MARK: - Dispatch: response.function_call_arguments.done → fulfill → the single send.
    func handleFunctionCall(
        _ event: OpenAIRealtimeResponseFunctionCallArgumentsDoneEvent,
        session: OpenAIRealtimeSession
    ) async {
        // ── DEFERRED branch ── SLOW tools return early via a Task so audio keeps flowing.
        // Decode is lenient (bad/empty args → ""); the provider degrades gracefully.
        if event.name == "web_search" {
            let query = Self.decodeArguments(SearchArguments.self, from: event.arguments)?.query ?? ""
            Task { [weak self] in
                guard let self else { return }
                let output = await self.performWebSearch(query)          // network hop (off the loop)
                await self.completeDeferredToolTurn(callID: event.callID, output: output, on: session)
            }
            return   // ← critical: do NOT fall through to the inline send
        }

        // ── INLINE branch ── FAST/local tools. Build `output` (+ an optional declarative
        // role:"system" context-sync note for tools that change state the prompt described).
        let output: String
        let contextSyncNote: String?

        switch event.name {
        case "get_time":
            // The canonical inline tool: dead simple, zero network.
            let now = ISO8601DateFormatter().string(from: Date())
            output = Self.jsonString(["now": now])
            contextSyncNote = nil

        default:
            // Lenient fallback: unknown tool → a graceful output, never a crash/wedge.
            output = Self.jsonString(["error": "unknown tool"])
            contextSyncNote = nil
        }

        // 1) The tool result. A bare item.create — triggers NO response by itself.
        await session.sendMessage(
            OpenAIRealtimeConversationItemCreate(
                item: .functionCallOutput(callID: event.callID, output: output)
            )
        )
        // 2) Optional system context-sync note (also bare — no response). Lets a tool keep the
        //    model's working set honest after a local state change. (No v1 tool sets one yet.)
        if let contextSyncNote {
            await session.sendMessage(
                OpenAIRealtimeConversationItemCreate(item: .init(role: "system", text: contextSyncNote))
            )
        }
        // 3) ── response.create SITE 3 of 4: INLINE TAIL ── set the guard BEFORE the send.
        self.responseInFlight = true
        await session.sendMessage(OpenAIRealtimeResponseCreate())
    }

    // MARK: - The SINGLE shared deferred tail — every slow tool funnels here, so the literal
    // response.create count stays at 4.
    func completeDeferredToolTurn(callID: String, output: String, on session: OpenAIRealtimeSession) async {
        await session.sendMessage(
            OpenAIRealtimeConversationItemCreate(
                item: .functionCallOutput(callID: callID, output: output)
            )
        )
        // ── response.create SITE 4 of 4: DEFERRED TAIL ── guard set BEFORE the send.
        self.responseInFlight = true
        await session.sendMessage(OpenAIRealtimeResponseCreate())
    }

    // MARK: - A choice tap is a NEW USER TURN (not a 2nd response on the show turn).
    // Public seam: wired by an interactive `choice` card in Tier 4 (no caller yet — expected).
    func sendUserChoice(_ text: String) async {
        guard let session = realtimeSession else { return }   // no live session → no-op
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // A bare user item never triggers a response on its own — safe even mid-turn.
        await session.sendMessage(
            OpenAIRealtimeConversationItemCreate(item: .init(role: "user", text: trimmed))
        )
        // Turn-guard: if a response is already in flight, a 2nd response.create would be
        // server-rejected — so the pick just rides the next free turn.
        guard !responseInFlight else { return }
        // ── response.create SITE 2 of 4: sendUserChoice ── guard set BEFORE the send.
        self.responseInFlight = true
        await session.sendMessage(OpenAIRealtimeResponseCreate())
    }

    // MARK: - Context nudge: a role:"system" item with NO response.create (takes no turn).
    // Use for LOCAL state changes the model should know about on its next turn. Adds ZERO
    // response.create sites — the count stays 4.
    func sendContextUpdate(_ systemText: String) async {
        guard let session = realtimeSession else { return }
        let trimmed = systemText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await session.sendMessage(
            OpenAIRealtimeConversationItemCreate(item: .init(role: "system", text: trimmed))
        )
        // NO response.create here.
    }

    // MARK: - web_search fulfillment (deferred). Routes through the injectable provider seam;
    // the default returns a graceful "unconfigured" envelope. NEVER throws (N1: no key here).
    func performWebSearch(_ query: String) async -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Self.jsonString(["status": "error", "message": "Empty search query."])
        }
        return await webSearch.search(query: trimmed)
    }
}

//  ─────────────────────────────────────────────────────────────────────────────
//  HOW TO ADD A TOOL  (recipe)
//  ─────────────────────────────────────────────────────────────────────────────
//  1. Add a Decodable args struct with OPTIONAL fields (malformed payload → nil, not a throw)
//     in ToolCatalog.swift.
//  2. Add its JSON-Schema `[String: AIProxyJSONValue]` and a `.function(.init(...))` entry to
//     `agentTools`, and mention it in `instructions(personality:)`.
//  3. Handle it in `handleFunctionCall`:
//       • FAST/local  → add a `case` to the switch; set `output` (+ optional `contextSyncNote`);
//                       it falls through to the SINGLE inline send.
//       • SLOW/network → handle it at the TOP with `Task { … await completeDeferredToolTurn(…) }`
//                        then `return`. Add NO response.create yourself.
//  4. A UI tool can also `self.emit(.component(…))` (Tier 4) to put a card on the glass.
//
//  GOLDEN RULE: never add a `response.create` to a tool turn — build on the inline fall-through
//  or the shared deferred tail. (SPEC N2: exactly 4 sites, forever.)
