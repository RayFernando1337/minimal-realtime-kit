#!/usr/bin/env bash
# Mint an ephemeral Realtime client secret (an `ek_...` token) the client can use to connect.
#
# WHO RUNS THIS: your backend — OR, for a pure BYO-key app, the device itself using the user's
# own key from the Keychain. NEVER ship a standing `sk-...` key in distributed source.
#
# Endpoint : POST https://api.openai.com/v1/realtime/client_secrets
# Auth     : a STANDARD OpenAI key (Bearer sk-...)
# TTL      : expires_after.seconds in [10, 7200]; default 600 (10 min) if omitted
# Returns  : { "value": "ek_...", "expires_at": <unix>, "session": { "id": "sess_...", ... } }
#            -> the client connects using `value` as its Bearer token.
#
# Docs: https://platform.openai.com/docs/guides/realtime-webrtc
#       https://developers.openai.com/api/reference/python/resources/realtime/subresources/client_secrets/methods/create/

set -euo pipefail

OPENAI_API_KEY="${OPENAI_API_KEY:-<<PASTE_YOUR_OWN>>}"   # standard sk-... key (server/Keychain only)

curl -sS https://api.openai.com/v1/realtime/client_secrets \
  -H "Authorization: Bearer ${OPENAI_API_KEY}" \
  -H "Content-Type: application/json" \
  -H "OpenAI-Safety-Identifier: <<HASHED_USER_ID>>" \
  -d '{
    "expires_after": { "anchor": "created_at", "seconds": 600 },
    "session": {
      "type": "realtime",
      "model": "gpt-realtime-2",
      "audio": { "output": { "voice": "marin" } }
    }
  }'

# Example response:
# {
#   "value": "ek_68af2...redacted",
#   "expires_at": 1799999999,
#   "session": { "id": "sess_ABC123", "type": "realtime", "model": "gpt-realtime-2", ... }
# }
