// mint-token.node.js — ~20-line Node/Express equivalent of the Cloudflare Worker.
// Same job: mint a short-lived OpenAI Realtime ephemeral client secret server-side so the
// standing key never reaches the device. Adapted from OpenAI's WebRTC guide /token example.
//   https://developers.openai.com/api/docs/guides/realtime-webrtc
//
// Run (user supplies their OWN key):
//   npm i express
//   OPENAI_API_KEY=sk-...  node mint-token.node.js
//   -> GET http://localhost:8787/token   (expose via your own HTTPS host for the app)

import express from "express";

const app = express();
const apiKey = process.env.OPENAI_API_KEY; // never hard-code; never commit

const sessionConfig = JSON.stringify({
  session: {
    type: "realtime",
    model: "gpt-realtime", // canonical model owned by research/06; keep in sync
    audio: { output: { voice: "marin" } },
    instructions: "You are a concise, friendly voice assistant.",
  },
  expires_after: { anchor: "created_at", seconds: 600 }, // 10s–7200s, default 600
});

app.get("/token", async (_req, res) => {
  try {
    const r = await fetch("https://api.openai.com/v1/realtime/client_secrets", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
        "OpenAI-Safety-Identifier": "hashed-user-id",
      },
      body: sessionConfig,
    });
    res.status(r.status).json(await r.json()); // app reads `value` + `expires_at`
  } catch (err) {
    console.error("Token generation error:", err);
    res.status(500).json({ error: "Failed to generate token" });
  }
});

app.listen(8787, () => console.log("token mint on :8787/token"));
