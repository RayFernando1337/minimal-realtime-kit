# Models & voices — quick reference (Jun 2026)

Verified live this session. Full citations in `../../research/06-openai-realtime-api.md` §1 & §6.

## Realtime models (current)

| String | Use | Notes |
|---|---|---|
| `gpt-realtime-2` | **Default / flagship** | GPT‑5‑class reasoning, 128K ctx, `reasoning.effort` (`minimal…xhigh`, default `low`), parallel tool calls, image input. Launched May 7–8 2026. |
| `gpt-realtime-1.5` | GA mid-gen | named replacement for the retired `gpt-4o-realtime-preview`. |
| `gpt-realtime` | First GA (alias) | snapshot `gpt-realtime-2025-08-28`; 32K ctx. |
| `gpt-realtime-mini` | Cost-optimized | replacement for `gpt-4o-mini-realtime-preview`. |
| `gpt-realtime-translate` | Live translation | 70+→13 langs; $0.034/min. |
| `gpt-realtime-whisper` | Streaming STT | **transcription sessions only**; `turn_detection` must be `null`. |

> Pin by alias `gpt-realtime-2`; confirm the exact dated snapshot in the dashboard before locking
> (the model page did not render a clean `gpt-realtime-2-YYYY-MM-DD`).

## RETIRED 2026-05-07 (do not use)

`gpt-4o-realtime-preview`, `gpt-4o-realtime-preview-2025-06-03`,
`gpt-4o-realtime-preview-2024-12-17`, `gpt-4o-mini-realtime-preview`, plus the **beta interface**
(`OpenAI-Beta: realtime=v1`). → replace with `gpt-realtime-1.5` / `gpt-realtime-mini` and the GA
interface. Source: <https://developers.openai.com/api/docs/deprecations>.

## Voices

`alloy`, `ash`, `ballad`, `coral`, `echo`, `sage`, `shimmer`, `verse`, **`marin`**, **`cedar`**
(lowercase, case-sensitive). Recommended: **`marin`** or **`cedar`**. Voice is **locked once the
model emits audio** in a session.

## Transcription models (for `audio.input.transcription.model`)

`whisper-1`, `gpt-4o-mini-transcribe`, `gpt-4o-mini-transcribe-2025-12-15`, `gpt-4o-transcribe`,
`gpt-4o-transcribe-diarize` (speaker labels), `gpt-realtime-whisper`.

## Audio formats (`audio.input.format` / `audio.output.format`)

`{ "type": "audio/pcm", "rate": 24000 }` (PCM16, 24kHz, mono, LE) · `{ "type": "audio/pcmu" }`
(G.711 μ-law) · `{ "type": "audio/pcma" }` (G.711 A-law).

## Pricing (per 1M tokens, `gpt-realtime-2`)

Text: $4 in / $24 out · Audio: $32 in ($0.40 cached) / $64 out · Image: $5 in.
Source: <https://developers.openai.com/api/docs/models/gpt-realtime-2>.
