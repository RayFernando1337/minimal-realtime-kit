# minimal-realtime-kit (staging / spec workspace)

> **Provisional working name** — rename when the real repo is created. This folder is the
> **basis for a brand-new, open-sourceable minimal repo**: a voice agent over the **latest
> OpenAI GPT Realtime API** with **tool calling**, distilled from the Pebbles
> (`OpenAIRealtimeSample`) app. **Bring-your-own-key only — ZERO of Ray's keys ship here.**

## Goal

Extract the *golden* parts of the big app into a **minimum viable** repo people can clone and
experiment with:

1. **Realtime voice** that feels like a real agent (always-open mic, barge-in, semantic VAD).
2. **Tool calling** with the one-`response.create`-per-turn discipline.
3. *(Stretch)* the **factory card pattern** (model passes data, never behavior) and the
   **SpriteKit character** driven by audio levels + state.

## Hard constraints

- **No secrets.** Never copy real API keys / AIProxy partial keys / service URLs into this folder.
  Use placeholders (`<<PASTE_YOUR_OWN>>`). The source app embeds real values in
  `OpenAIRealtimeSample/RealtimeManager.swift` (~L182-183, ~L862-863) — those must be redacted.
- **Latest GPT Realtime.** Target the current GA realtime model + API surface (verified via live docs).
- **Minimal first.** Ship the realtime+tools core; everything else is layered/optional.

## Layout

```
minimal-realtime-kit/
├── README.md            ← this file
├── SPEC.md              ← (synthesized by orchestrator) the architecture spec to build
├── PROJECT-PLAN.md      ← (synthesized) phased, agent-ready build plan
├── research/            ← per-subsystem extraction handoffs (one file per worker)
│   ├── 01-realtime-core.md
│   ├── 02-factory-pattern.md
│   ├── 03-spritekit-character.md
│   ├── 04-composition-surface.md
│   ├── 05-config-keys-build.md
│   ├── 06-openai-realtime-api.md      ← live API research
│   └── 07-aiproxy-byok-keys.md        ← SDK + keyless/BYOK research
└── snippets/            ← extracted, REDACTED code snippets (one subdir per worker)
    ├── realtime/  factory/  spritekit/  composition/  config/  api-reference/  keys/
```
