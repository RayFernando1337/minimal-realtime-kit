# snippets/keys — BYO-key handling (redacted, copy-pasteable)

Two key modes behind one seam, so the realtime client never has to care where the credential
came from. **No secrets in any file — users bring their own key.**

| File | Side | Role |
| --- | --- | --- |
| `KeychainStore.swift` | iOS | Store/load/delete a user-pasted key in the Keychain (device-only). |
| `RealtimeCredentialProvider.swift` | iOS | The seam: `PastedKeyProvider` (Mode A) vs `EphemeralTokenProvider` (Mode B). |
| `EphemeralTokenClient.swift` | iOS | Fetch a short-lived `ek_...` token from the user's backend. |
| `mint-token.worker.js` | Backend | Cloudflare Worker that mints the ephemeral token (the whole backend). |
| `mint-token.node.js` | Backend | ~20-line Node/Express equivalent. |

## Two modes

- **Mode A — paste-your-own-key (instant local trial).** User pastes their `sk-...` key; it
  lives in the Keychain on-device; the realtime socket authenticates with it directly. Zero
  backend. Caveat: a standing key sits on the device.
- **Mode B — ephemeral token (right long-term default).** A tiny backend the *user* deploys
  holds the standing key and mints short-lived `ek_...` tokens (default 10 min). The device
  only ever holds an expiring token.

Ship BOTH: `RealtimeCredentialProvider` makes them interchangeable.

## Wiring

```swift
// Mode A:
let provider: RealtimeCredentialProvider = PastedKeyProvider()
// Mode B:
let provider: RealtimeCredentialProvider = EphemeralTokenProvider(
    tokenEndpoint: URL(string: "https://<your-worker>.workers.dev/token")!
)

let cred = try await provider.credential()
// connect realtime transport with  Authorization: Bearer \(cred.bearer)
```

> Model name (`gpt-realtime`) and the realtime wire protocol are owned by `research/06`. Keep
> the `model` in the backend snippets in sync with that file.
