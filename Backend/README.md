# Flowy — the local server (Backend)

A small FastAPI server that runs on `127.0.0.1:50711`. It does two jobs:

1. **Transcribe** your voice to text, locally (`faster-whisper`, on-device).
2. **Relay** assistant questions to the LLM provider you pick, and stream the
   answer back.

The Mac app **starts and stops this server for you** — you normally never run it
by hand. This README is for understanding or changing it.

> New here? The [top-level README](../README.md) is the 2-minute setup.

---

## Run it directly (for debugging)

```bash
cd Backend
uv sync                          # create .venv + install deps (one time)
uv run python -m flowy.server    # serve on http://127.0.0.1:50711
uv run pytest -q                 # tests
```

Requires `uv` (which also fetches Python). The app auto-launches the same
`.venv`, so `uv sync` is all the setup the app needs.

---

## The endpoints

| Method | Path | In → Out |
|---|---|---|
| `GET` | `/health` | → `{"status":"ok"}` |
| `POST` | `/transcribe` | raw audio bytes (+ optional `X-Flowy-Hotwords`, `X-Flowy-Prompt` base64 headers) → `{"text": "..."}` |
| `POST` | `/assistant` | JSON `{text, provider, model, api_key, base_url?, system_prompt?, images?, history?}` → `{"text": "..."}` |
| `POST` | `/assistant/stream` | same body → **NDJSON stream**: `{"delta":"..."}` per chunk, then `{"done":true}` (or `{"error":"..."}`) |
| `POST` | `/models` | `{provider, api_key, base_url?}` → `{"models":[...]}` (the provider's live list) |

Keys are sent per-request by the app (which stores them in the macOS Keychain) —
nothing is read from the environment or written to disk here.

---

## The map

Source is under `src/flowy/`.

| File | What it does |
|---|---|
| `server.py` | The FastAPI app + all the routes above. Loads the model + a warm-up pass at startup so the first dictation is instant. |
| `transcribe.py` | Speech-to-text via `faster-whisper`. Model loaded once and reused. A swappable seam — the STT engine can be replaced without touching the server. |
| `assistant.py` | The LLM layer: `answer()` / `answer_stream()` that speak each provider's HTTP API, build multimodal + multi-turn payloads, and list models. |
| `cli.py`, `core.py` | Legacy Gemma-translation experiment (not on the app's path). |

### Providers (`assistant.py`)

`anthropic` · `openai` · `gemini` · `openai_compatible` (a custom `base_url` —
OpenRouter, Groq, or a **local** Ollama / LM Studio at `http://localhost:11434/v1`).
Each supports streaming (SSE), images, and prior-turn history; the app decides
what to send. Note: native OpenAI uses `max_completion_tokens`; OpenAI-compatible
servers still get `max_tokens`.

### Prompts (`prompts/`)

Drop a `.md`/`.txt` file here and it appears in the app's Settings → Assistant →
Prompt picker; its contents become the system prompt. Ships with `assistant.md`,
`rewrite.md`, `email-reply.md`. Edit freely — changes apply on the next request.

---

## Config

| Env var | Default | Effect |
|---|---|---|
| `FLOWY_WHISPER_MODEL` | `tiny.en` | STT model. `base.en` for more accuracy, `base` for multilingual. |

```bash
launchctl setenv FLOWY_WHISPER_MODEL base.en    # then Quit & reopen Flowy
```

Speed: `tiny.en` is ~1.8s for a 7s clip on an M4. The first run downloads the
model (~75 MB from Hugging Face) once; after that transcription is fully offline.

---

## Swapping the STT engine

`transcribe.py` hides the engine behind a single `transcribe()` function, so a
different local model (e.g. Gemma 4 E2B) can slot in without changing `server.py`.
