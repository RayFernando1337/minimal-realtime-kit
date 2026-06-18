# snippets/api-reference

Copy-pasteable references for the **current (2026) OpenAI Realtime API**, extracted from live
OpenAI docs. These are **illustrative** (REDACTED — no keys; use `<<PASTE_YOUR_OWN>>`). Full
prose + citations live in `../../research/06-openai-realtime-api.md`.

| File | What it shows |
|---|---|
| `01-mint-ephemeral-client-secret.sh` | Mint a short-lived `ek_…` token via `POST /v1/realtime/client_secrets` |
| `02-session-update.ga.json` | The GA **nested** `session.update` payload (audio.input/output, semantic VAD, reasoning) |
| `03-function-call-loop.jsonl` | The realtime tool loop: declare → `function_call` → `function_call_output` → `response.create` |
| `04-mcp-tool.json` | API-executed `mcp` tool + built-in connector shape |
| `05-websocket-connect.swift` | Dependency-free `URLSessionWebSocketTask` connect + event send (minimal-core transport) |
| `06-webrtc-connect.swift` | WebRTC SDP flow to `POST /v1/realtime/calls` (OpenAI-recommended client transport) |
| `models-and-voices.md` | Current model strings, voices, deprecations quick-reference |

**Model used throughout:** `gpt-realtime-2`. **Transport recommendation:** WebRTC for clients;
WebSocket is fine for a zero-dependency minimal core (you own audio I/O + truncation).
