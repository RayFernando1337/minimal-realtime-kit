// mint-token.worker.js — Cloudflare Worker that mints a short-lived OpenAI Realtime
// ephemeral client secret. This is the *entire* "backend" for the ephemeral-token mode.
//
// Deploy (user runs this with THEIR OWN key; the author ships zero keys):
//   1) npm create cloudflare@latest token-mint   (or paste into the dashboard editor)
//   2) npx wrangler secret put OPENAI_API_KEY     (stores the standing key as a secret)
//   3) npx wrangler deploy
//   -> gives a URL like https://token-mint.<you>.workers.dev/token  (put that in the app)
//
// GA endpoint: POST https://api.openai.com/v1/realtime/client_secrets
//   - Auth with your STANDING key (Bearer) — server-side only.
//   - Body wraps config in { session: { type: "realtime", model, ... } }.
//   - Response carries the ephemeral secret at top-level `value` ("ek_...").
//   - Set OpenAI-Safety-Identifier so abuse is attributable to a hashed user id.
//   Docs: https://developers.openai.com/api/docs/guides/realtime-webrtc
//         https://developers.openai.com/api/reference/resources/realtime/subresources/client_secrets/methods/create/

export default {
  async fetch(request, env) {
    // Lock this down in production: CORS allow-list, app-attest / your own auth, rate limits.
    if (request.method !== "GET" && request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    const sessionConfig = {
      session: {
        type: "realtime",
        model: "gpt-realtime", // canonical model owned by research/06; keep in sync
        audio: { output: { voice: "marin" } },
        instructions: "You are a concise, friendly voice assistant.",
      },
      // TTL: 10s–7200s, default 600 (10 min). Short is safer.
      expires_after: { anchor: "created_at", seconds: 600 },
    };

    const r = await fetch("https://api.openai.com/v1/realtime/client_secrets", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.OPENAI_API_KEY}`,
        "Content-Type": "application/json",
        "OpenAI-Safety-Identifier": "hashed-user-id", // bind token to a hashed user id
      },
      body: JSON.stringify(sessionConfig),
    });

    // Pass OpenAI's JSON straight through; the app reads `value` + `expires_at`.
    return new Response(r.body, {
      status: r.status,
      headers: { "Content-Type": "application/json" },
    });
  },
};
