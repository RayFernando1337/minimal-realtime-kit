# 07 — SDK + Key-Handling Decision (BYO-key, open-source iOS realtime)

> **Worker slice:** the **SDK choice + key-handling decision + iOS secret storage** for a new,
> minimal, open-source BYO-key iOS realtime-voice + tool-calling app. The current app uses
> **AIProxySwift** in *proxied* mode (routes through the author's AIProxy account) — **not
> acceptable** for an OSS repo where the author ships zero keys and every user brings their own.
>
> **Coordinates with worker F / `research/06`** (raw OpenAI ephemeral-token + realtime wire
> mechanics). This file does **not** re-document the full realtime API surface; it cites `06`
> for the canonical model name and wire protocol and focuses on the *decision*.
>
> Date: 2026-06-17. Versioned facts pulled from live sources; every headline claim cites a URL
> with a confidence tag.

---

## TL;DR recommendation

1. **Key handling — ship BOTH, behind one seam.**
   - **Mode A (default for "experiment today"): paste-your-own-key**, stored in the iOS
     **Keychain** (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). Zero backend; instant trial.
   - **Mode B (the right long-term default): ephemeral client secrets** minted by a **tiny
     backend the user runs** (a ~15-line Cloudflare Worker or Node/Express endpoint hitting
     `POST /v1/realtime/client_secrets`). The standing key never reaches the device.
   - A one-protocol seam (`RealtimeCredentialProvider`) makes them interchangeable — the
     realtime transport only ever needs `Authorization: Bearer <credential>`.

2. **SDK — start on AIProxySwift in *direct/unprotected* (BYOK) mode; design to drop it later.**
   AIProxySwift (MIT, actively released, GA-realtime-ready) gives you the entire realtime audio
   pipeline for free and is literally what the `lzell/OpenAIRealtimeSample` starter uses. Its
   `AIProxy.openAIDirectService(unprotectedAPIKey:)` path is purpose-built for BYOK and needs
   **no** AIProxy account/backend. **Caveat:** AIProxySwift's realtime path is documented only
   for a *direct standing key* over WebSocket — it does **not** document the ephemeral
   `ek_...` flow. So Mode B (ephemeral) likely needs the official/hand-rolled transport. Put the
   transport behind a small protocol so the repo can move to a **hand-rolled
   `URLSessionWebSocketTask`** client (zero deps, full header control, future-proof) when you
   want Mode B to be first-class.

Full tradeoff tables at the bottom.

---

## Q1 — AIProxySwift current state

**Latest version: `0.153.0`, published 2026-05-12; repo `lzell/AIProxySwift`, MIT, ~439★,
last push 2026-06-10 (active).** — confidence **high**
(GitHub releases/repo API: `gh api repos/lzell/AIProxySwift/releases`, `.../tags`, repo meta.)
Note the tag scheme switched from `vX.Y.Z` (older, e.g. `v0.131.1`) to bare `X.Y.Z` (recent
releases), so the newest *release* `0.153.0` outranks the `v0.131.x` tags.

**Does it support realtime sessions? YES.** The README ships a full realtime example built on
`openAIService.realtimeSession(model:configuration:logLevel:)`, with `OpenAIRealtimeSessionConfiguration`
(semantic VAD, voices, modalities), `OpenAIRealtimeInputAudioBufferAppend`, `responseAudioDelta`,
`OpenAIRealtimeResponseCreate`, and an `AudioController` for mic/playback. It also has a
**"General Availability (GA) Realtime migration notes"** section: `gpt-realtime`,
`output_modalities` (replacing `modalities`), `.webSearch` GA tool, and a note that the beta
`OpenAI-Beta: realtime=v1` header is deprecated/shut down 2026-05-07. — confidence **high**
(README: `lzell/AIProxySwift` `# How to use realtime audio with OpenAI`).

**Does it support a DIRECT bring-your-own-key path, incl. realtime? YES.**
`AIProxy.openAIDirectService(unprotectedAPIKey: "your-openai-key")` appears as the documented
**"Uncomment for BYOK use cases"** alternative in *every* example, **including the realtime
snippet** (right next to the proxied `openAIService(partialKey:serviceURL:)`). README explicitly:
*"We only recommend making requests straight to the provider during prototyping and for BYOK
use-cases."* and *"this is not required if you are shipping an app where the customers provide
their own API keys (known as BYOK)."* — confidence **high** (README intro + realtime snippet).

**AIProxy's stance on shipping keys / DeviceCheck / partial keys.** The *proxied* path applies
five protections — **certificate pinning, DeviceCheck verification, split-key encryption,
per-user rate limits, per-IP rate limits** — and uses a `partialKey` + `serviceURL` from the
AIProxy developer dashboard (so the full key lives on AIProxy's backend, not in the app). That
is AIProxy's pitch for *first-party* keys. — confidence **high** (README `# About`).

**Is the direct/unprotected path suitable for an OSS demo where each user pastes their OWN key?
YES — that is exactly its stated BYOK use case**, and it needs **no AIProxy account**. The
important nuance for *this* repo:
- The **proxied** mode is unusable for us (it would route through *the author's* AIProxy account
  / partial key — the thing we're removing). — confidence **high** (by construction).
- The **direct** mode keeps a *standing* key on-device (the user's own). Fine for BYOK
  experimentation; weaker than ephemeral tokens for a shipped app. — confidence **high**.
- AIProxySwift's **realtime** path is documented **only** with a direct standing key over
  WebSocket; the README shows **no** ephemeral `client_secret`/`ek_...` support. So pairing
  AIProxySwift-realtime with ephemeral tokens is **undocumented / unverified**. — confidence
  **med** (based on *absence* in docs; grep for `client_secret|ephemeral|ek_` in the README → 0
  hits; not the same as proven impossible).

---

## Q2 — Keyless / BYO-key options (with tradeoffs)

### (a) Paste-your-own-key in-app (Keychain)
- **What:** user pastes their `sk-...` key; app stores it in the Keychain; realtime socket
  authenticates with it directly.
- **Pros:** simplest possible; zero backend; instant local trial; nothing for the author to run
  or pay for; great for a clone-and-go OSS demo.
- **Cons / caveats:** a **long-lived** secret sits on the device — if exfiltrated (jailbreak,
  malware, shoulder-surf during paste) it's a full-scope key until the user revokes it. No
  server-side rate-limit/abuse cap. Users uncomfortable pasting keys will balk. Mitigate with
  Keychain `...ThisDeviceOnly`, a visible "Forget my key" control, and clear copy that the key
  stays on-device. — confidence **high** (security model is well understood; Apple Keychain docs).

### (b) Ephemeral client secret via a tiny backend (OpenAI-recommended)
- **What:** a minimal server holds the standing key and calls
  **`POST https://api.openai.com/v1/realtime/client_secrets`** to mint a short-lived `ek_...`
  token (TTL **10s–7200s, default 600s/10min**); the app fetches that token and connects with
  it. The beta `POST /v1/realtime/sessions` endpoint is **retired** — must use
  `client_secrets`; the token is read at top-level **`value`** (GA), not `client_secret.value`;
  drop the `OpenAI-Beta` header when connecting with the ephemeral key. — confidence **high**
  (OpenAI API ref + WebRTC guide + corroborating community migration note; see Sources).
- **Minimal backend:** genuinely ~15–20 lines. A **Cloudflare Worker** (`mint-token.worker.js`)
  or **Node/Express** (`mint-token.node.js`) endpoint — both provided under `snippets/keys/`.
  Set `OpenAI-Safety-Identifier` on the mint request so OpenAI binds abuse to a hashed user id.
- **Pros:** standing key never touches the device; tokens auto-expire; you can add auth/rate
  limits/CORS at the edge; this is the pattern OpenAI documents for mobile/web clients.
- **Cons:** the user must deploy + host something (Workers free tier makes this ~5 min, but it's
  still a step); still requires a standing key to live *somewhere* (the user's server/secret
  store); slightly more moving parts for a "just clone it" demo.

### (c) Keep AIProxySwift, but with the user's OWN AIProxy account (or direct unprotected key)
- **User's own AIProxy account (proxied):** gives DeviceCheck + split-key + rate limits on the
  user's *own* key, but forces every OSS user to sign up for AIProxy and provision a
  `partialKey`/`serviceURL` — a third-party dependency + account for a "minimal demo." Reasonable
  as an *opt-in* for someone who wants those protections; **not** a good default. — confidence
  **high** (matches AIProxy's own framing).
- **Direct unprotected key via AIProxySwift:** identical security profile to option (a)
  (standing key on device) but you inherit AIProxySwift's audio/realtime plumbing. This is the
  pragmatic "fastest to working" choice for v1. — confidence **high**.

### Recommendation for Q2
- **"Minimum viable, people can experiment today" → (a) paste-key in Keychain.** One screen, no
  backend, works on a fresh clone.
- **"Right long-term default" → (b) ephemeral tokens.** Standing key off-device, expiring creds,
  abuse controls.
- **Offer BOTH** behind `RealtimeCredentialProvider` (snippet provided): `PastedKeyProvider`
  (Mode A) and `EphemeralTokenProvider` (Mode B). The realtime client is identical either way.
- Treat (c) as an **opt-in note in docs**, not a default.

---

## Q3 — SDK choice for the new repo

Three candidates, weighed on realtime support, BYOK fit, dependency weight, OSS-friendliness,
maintenance:

1. **AIProxySwift (direct/unprotected BYOK mode).**
   - *Realtime:* yes, GA-ready (semantic VAD, voices, web_search tool, output_modalities).
   - *BYOK fit:* first-class for paste-key (`openAIDirectService(unprotectedAPIKey:)`); **no
     documented ephemeral-token path** for realtime.
   - *Dep weight:* one SPM package that bundles many providers (OpenAI, Gemini, Anthropic, …) —
     heavier than needed for an OpenAI-only minimal repo.
   - *OSS-friendliness:* **MIT** ✔; active releases ✔; but its identity/branding is tied to the
     AIProxy product, and the proxied path advertises the author-account model we're removing.
   - *Maintenance:* maintained by a third party on a fast release cadence (you track *their*
     versions; the realtime API moved beta→GA recently).
   - **Verdict:** **best "ship today" choice**; gives the whole audio loop for free and matches
     the lzell starter. Use it for v1 paste-key mode.

2. **OpenAI's official approach.** There is no first-party *Swift* realtime SDK; the official
   guidance is the **ephemeral-token + WebRTC/WebSocket** pattern (server mints `ek_...`, client
   connects). For Swift you implement the client yourself (or via a community lib). This *is* the
   correct shape for Mode B, but it's a pattern, not a drop-in Swift package. — confidence
   **high** (OpenAI WebRTC guide; openai-python has `realtime/client_secrets`, no official Swift).

3. **Lightweight hand-rolled WebSocket client (`URLSessionWebSocketTask`).**
   - *Realtime:* connect to the GA realtime WS with `Authorization: Bearer <sk-… or ek_…>`; send/
     receive JSON events. (WebRTC is the other transport but pulls in the heavyweight WebRTC
     framework — overkill for a minimal iOS app; WS is the lean choice and is what AIProxySwift
     uses under the hood.)
   - *BYOK fit:* **best** — you control the `Authorization` header, so paste-key *and* ephemeral
     `ek_...` both "just work" (and you can omit the retired `OpenAI-Beta` header cleanly).
   - *Dep weight:* **zero third-party deps.**
   - *OSS-friendliness:* **highest** — fully self-contained, license-clean, no product branding,
     not coupled to anyone's release cadence.
   - *Maintenance:* you own ~a few hundred lines (WS + a small event enum + the audio plumbing,
     which you can lift from the existing app's patterns). You must track OpenAI's event schema
     yourself.
   - **Verdict:** **best long-term core**, especially because it's the clean way to support
     ephemeral tokens (Mode B) as a first-class citizen.

**Is `lzell/OpenAIRealtimeSample` a good minimal reference?** As a **read-only reference, yes**
— it's the canonical "AIProxySwift realtime on iOS" starting point the README points to. As a
**base to fork, no:** it's **unlicensed** (`license: null` via GitHub API → all-rights-reserved
by default, not safe to reuse in an OSS repo), tiny (**3★**), and a single **"Initial commit"
(2025-12-31)** with no ongoing maintenance. Learn the wiring from it; don't build on it. —
confidence **high** (GitHub repo + commits API).

### Recommendation for Q3
- **v1 (ship fast):** AIProxySwift in **direct BYOK mode** for paste-key, *behind a transport
  protocol*. You get GA realtime audio immediately.
- **v1.x / long-term:** add the **hand-rolled `URLSessionWebSocketTask`** transport to make
  **ephemeral tokens** first-class and to drop the third-party dependency for a leaner,
  license-clean OSS core.
- Either way, **decouple the transport from the credential** (`RealtimeCredentialProvider`) so
  the SDK swap and the key-mode swap are independent, reversible decisions.

> If "zero deps + license-clean + ephemeral-first" matters more than shipping speed, **hand-roll
> the WS from day one** and lift audio patterns from the current app — skip AIProxySwift
> entirely. Both paths are defensible; the tables below make the tradeoff explicit.

---

## Q4 — iOS Keychain / secret storage best practice (pasted key)

- **Use the Keychain, never `UserDefaults`/`@AppStorage`/a plist/file** for the pasted key —
  Keychain is hardware-encrypted + access-controlled; the others are plaintext at rest. —
  confidence **high** (Apple "Storing Keys in the Keychain").
- **Item class:** `kSecClassGenericPassword`, keyed by `kSecAttrService` (bundle id) +
  `kSecAttrAccount` (e.g. `"openai_api_key"`).
- **Accessibility:** **`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`** — readable only while
  the device is unlocked and **does not migrate to other devices via backup/restore** (right
  posture for a sensitive, device-bound secret). For an even stricter bar,
  `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` ties the item to the passcode (item is
  removed if the passcode is disabled). Avoid the deprecated `kSecAttrAccessibleAlways`. —
  confidence **high** (Apple `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` page; corroborated
  by Swift Keychain write-ups in Sources).
- **Writes:** delete-then-`SecItemAdd` (or `SecItemUpdate`) so re-pasting overwrites cleanly.
- **UX:** always provide a **"Forget my key"** action (`SecItemDelete`) and tell the user the
  key stays on their device. (Optional: gate read behind biometrics via
  `SecAccessControl`/`LAContext` for extra protection.)
- Copy-pasteable impl: **`snippets/keys/KeychainStore.swift`**.

---

## Q5 — Minimal backend token-mint snippet(s) + iOS fetch

Provided under `snippets/keys/` (redacted, no secrets):

- **`mint-token.worker.js`** — Cloudflare Worker (the whole "backend"): `POST` to
  `https://api.openai.com/v1/realtime/client_secrets` with the standing key (a Wrangler secret),
  body `{ session: { type:"realtime", model:"gpt-realtime", … }, expires_after:{ anchor:"created_at", seconds:600 } }`,
  `OpenAI-Safety-Identifier` set, response passed straight through.
- **`mint-token.node.js`** — ~20-line Node/Express equivalent (adapted from OpenAI's WebRTC guide
  `/token` example).
- **`EphemeralTokenClient.swift`** — iOS fetch: calls the user's `/token`, decodes top-level
  **`value`** (`ek_...`) + `expires_at`.
- **`RealtimeCredentialProvider.swift`** — the seam unifying paste-key and ephemeral modes.

All facts (endpoint, body wrapping, `value` field, TTL bounds, retired `sessions` endpoint,
dropping `OpenAI-Beta`) are from current OpenAI docs — see Sources. Canonical **model name** and
the **realtime wire protocol** are owned by `research/06`; keep the snippets' `model` in sync.

---

## RECOMMENDATION (decision) + tradeoff tables

**Decision:**
- **Key handling:** ship **paste-key (Keychain)** *and* **ephemeral-token (tiny user backend)**,
  unified by `RealtimeCredentialProvider`. Default the first-run experience to **paste-key**
  (zero friction); document ephemeral tokens as the recommended hardening / "real app" path.
- **SDK:** **v1 on AIProxySwift direct BYOK mode** for instant GA realtime; **decouple transport
  via a protocol** and migrate the realtime transport to a **hand-rolled
  `URLSessionWebSocketTask`** client to make ephemeral tokens first-class and shed the dependency
  for the long-term OSS core. Use `lzell/OpenAIRealtimeSample` as a *reference only* (unlicensed,
  unmaintained — don't fork).

### Table A — Key-handling options

| Option | Backend needed | Key exposure | Abuse controls | Setup friction | OSS-demo fit | Verdict |
| --- | --- | --- | --- | --- | --- | --- |
| **(a) Paste-key + Keychain** | None | Standing key on device (user's own) | None (device-side only) | Lowest (one screen) | ★★★ | **Default for "try it today"** |
| **(b) Ephemeral token + tiny backend** | ~15-line Worker/Node | Only expiring `ek_...` on device; standing key on server | Edge auth + rate limit + safety id; auto-expiry | Medium (deploy 1 endpoint) | ★★ | **Right long-term default** |
| **(c-i) User's own AIProxy acct (proxied)** | AIProxy account | Full key on AIProxy backend | DeviceCheck, split-key, rate limits | High (3rd-party signup) | ★ | Opt-in note only |
| **(c-ii) AIProxySwift direct unprotected** | None | Standing key on device | None | Low | ★★★ | = (a), but via the SDK |

### Table B — SDK options

| SDK | Realtime (GA) | Paste-key | Ephemeral-token fit | Deps | OSS-friendly | Maintenance | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **AIProxySwift (direct BYOK)** | ✔ built-in | ✔ first-class | ✖ undocumented for realtime | 1 multi-provider pkg (MIT) | MIT ✔ / product-branded | 3rd-party, fast cadence | **Ship v1 fast** |
| **Official OpenAI pattern (ephemeral + WebRTC/WS)** | ✔ (pattern) | ✔ | ✔ first-class | WebRTC = heavy; or DIY WS | ✔ | OpenAI docs (you track schema) | Adopt the *pattern* for Mode B |
| **Hand-rolled `URLSessionWebSocketTask`** | ✔ (you implement events) | ✔ | ✔ **best** (full header control) | **zero** | **highest** | you own ~few hundred LOC | **Best long-term core** |

---

## Sources (URLs)

- AIProxySwift README (realtime, BYOK direct service, DeviceCheck/partial-key, GA notes):
  https://github.com/lzell/AIProxySwift  (raw: https://raw.githubusercontent.com/lzell/AIProxySwift/main/README.md)
- AIProxySwift releases / tags / repo meta (v0.153.0, MIT, ★439, active):
  `gh api repos/lzell/AIProxySwift/releases` · `.../tags` · `gh api repos/lzell/AIProxySwift`
- `lzell/OpenAIRealtimeSample` (reference starter; unlicensed, ★3, single initial commit):
  https://github.com/lzell/OpenAIRealtimeSample  (`gh api repos/lzell/OpenAIRealtimeSample` + `/commits`)
- OpenAI — Create client secret (GA endpoint, body shape, TTL 10–7200s/default 600, `value`):
  https://developers.openai.com/api/reference/resources/realtime/subresources/client_secrets/methods/create/
- OpenAI — Realtime with WebRTC (ephemeral-token pattern, `/token` server example, `OpenAI-Safety-Identifier`, `/v1/realtime/calls`):
  https://developers.openai.com/api/docs/guides/realtime-webrtc
- openai-python `realtime/client_secrets` (confirms the resource exists in the official SDK):
  https://github.com/openai/openai-python/blob/main/src/openai/resources/realtime/client_secrets.py
- Migration corroboration (beta `/v1/realtime/sessions` retired; read token at `response.value`; drop `OpenAI-Beta`):
  https://community.openai.com/t/sudden-since-06-10-2026-failure-in-eu-api-openai-com-invalid-url-post-v1-realtime-sessions/1383405/5
- Azure Foundry GA WebRTC (independent confirmation of `client_secrets` GA endpoint shape):
  https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/realtime-audio-webrtc
- Apple — Storing Keys in the Keychain:
  https://developer.apple.com/documentation/security/storing-keys-in-the-keychain
- Apple — `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`:
  https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly
- Swift Keychain practice (accessibility table; corroborating, secondary):
  https://oneuptime.com/blog/post/2026-02-02-swift-keychain-secure-storage/view

---

## Open questions / unverified

- **AIProxySwift + ephemeral `ek_...` for realtime:** not documented; README has 0 hits for
  `client_secret`/`ephemeral`/`ek_`. Whether `openAIDirectService(unprotectedAPIKey:)` can be
  handed an ephemeral token (and whether the SDK omits the now-retired `OpenAI-Beta` header on
  the realtime WS) is **unverified** — would require reading AIProxySwift source. This is the
  main reason the long-term recommendation favors a hand-rolled WS for Mode B. (med)
- **Exact GA realtime model id** to default to (`gpt-realtime` vs `gpt-realtime-2` vs a dated
  snapshot) and the precise WS URL/handshake are **owned by `research/06`** — snippets here use
  `gpt-realtime` as a placeholder to keep in sync. (deferred by design)
- **Response field name** for the ephemeral secret: GA = top-level **`value`** per the WebRTC
  guide + community migration note; the API-reference "Returns" block emphasizes `expires_at` +
  `session` and describes the secret as an `ek_1234` string. Treated as `value`. (high, but
  worker F should confirm against a live mint if possible.)
- **WebRTC vs WebSocket** for the hand-rolled client: WS chosen for minimalism (no WebRTC
  framework); WebRTC may give better NAT traversal/jitter handling. Transport tradeoff is
  `research/06`'s call. (low — out of this slice)

## Confidence & verification

- **High:** AIProxySwift version/realtime/BYOK-direct/DeviceCheck framing (live README + GitHub
  API); `OpenAIRealtimeSample` unlicensed/unmaintained (GitHub API); Keychain best practice
  (Apple docs); ephemeral-token endpoint + TTL + retired `sessions` endpoint (OpenAI docs +
  Azure GA doc + community migration note agree).
- **Med:** AIProxySwift's (in)compatibility with ephemeral tokens for realtime (inferred from
  doc absence, not source-verified); precise ephemeral response field (`value`).
- **Verification method:** GitHub REST API for versioned repo facts; primary vendor docs
  (OpenAI, Apple) for API/security claims; one community thread + Microsoft Learn used only to
  *corroborate* the GA endpoint migration, not as sole source. Did **not** read the app source
  (per instructions). No live token mint was executed (no key available in this worker).
