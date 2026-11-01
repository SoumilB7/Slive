# Slive Server (Backend)

A small FastAPI server on `127.0.0.1:50711`. The Mac app is its only client and
**starts and stops it for you**. It:

1. **Relays** assistant questions to the LLM provider you pick, and streams the
   answer back.
2. Runs **on-device Hugging Face models** (download, cache, chat, transcribe).
3. Labels and **fine-tunes Whisper** on your own dictations.

Dictation itself runs in the app (WhisperKit), not here.

> New here? The [top-level README](../README.md) is the 2-minute setup.

---

## Run it directly (for debugging)

```bash
cd Backend
uv sync --extra training            # everything (what install-full does)
uv run python -m flowy.server       # serve on http://127.0.0.1:50711
uv run --extra dev pytest -q        # tests (dev includes training)
```

| Install | Gets |
|---|---|
| `uv sync` | the server + cloud providers only (FastAPI, uvicorn, httpx, pydantic) |
| `uv sync --extra local` | + on-device models (torch, transformers, torchao, …) |
| `uv sync --extra training` | + Whisper fine-tuning (peft, psutil); includes `local` |

ML packages are imported lazily, so a base install still serves `/health` and
the cloud routes.

---

## The endpoints

Requests must come from the app: a loopback `Host` and no `Origin` (else 403).
Errors are `{"error": "<message>"}`.

| Method | Path | In → Out |
|---|---|---|
| `GET` | `/health` | → `{"status":"ok","busy":bool}` (busy = a job or request is running) |
| `POST` | `/assistant` | `{text, provider, model, api_key, base_url?, system_prompt?, max_tokens?, images?, history?, local_quantized?, local_mem_gb?}` → `{"text"}` |
| `POST` | `/assistant/stream` | same body → **NDJSON**: `{"delta"}` per chunk, then `{"done":true}` or `{"error"}` |
| `POST` | `/models` | `{provider, api_key, base_url?}` → `{"models":[...]}` |
| `GET` | `/transcribe_llm/prompt` | → `{"prompt"}` (the default instruction) |
| `POST` | `/transcribe_llm` | `{provider, model, api_key, audio_b64, …}` → `{"text","prompt"}` |
| `POST` | `/label_consensus` | `{api_key, audio_b64, typed?, hotwords?, context?, base_prompt?}` → `{"text","chosen","agreement","candidates","prompt"}`; a bad key is 401 + `"fatal"` |
| `GET` | `/local/cache` | → `{"models":[...]}` |
| `POST` | `/local/download` | `{repo_id, token?}` → `{"job_id"}`; poll `GET /local/download/{id}` |
| `POST` | `/local/delete` | `{repo_id}` → `{"deleted"}` |
| `GET` | `/training/models`, `/training/readiness`, `/training/jobs/latest`, `/training/jobs/{id}` | catalog, readiness, job polls |
| `POST` | `/training/start`, `/training/jobs/{id}/resume` | → 202 `{"job"}`; 409 conflict, 422 bad input, 424 missing dependency |

Keys are sent per request by the app (which keeps them in the Keychain) —
nothing is written to disk here.

---

## The map

Source is under `src/flowy/`.

| Path | What it does |
|---|---|
| `server.py` | Entry point: `app = create_app(...)`, `main()` (`slive-server`, `python -m flowy.server`). |
| `api/app.py` | `create_app(settings, services)` — routers, middleware, error handler. |
| `api/routes/` | One router per area: `health`, `assistant`, `labels`, `local`, `training`. |
| `api/schemas.py` | Request bodies (one `ChatRequest` for both assistant routes). |
| `api/services.py` | What routes depend on (`Services`); production = the domain modules. |
| `api/middleware.py` | Local-app-only guard, in-flight request count. |
| `errors.py` | `AppError` types (400/401/404/409/422/424/502) and the one handler. |
| `providers/` | LLM providers behind a registry + `Gateway` (below). |
| `jobs/runner.py` | `JobRunner`: background jobs, lock, `busy()` — downloads and training. |
| `local.py` / `local_infer.py` | Hugging Face cache + downloads / on-device inference. |
| `label_consensus.py` | 3-way consensus labels (gpt-transcribe + whisper-1 + typed). |
| `training/` | Training store, model catalog, pipeline, jobs ([docs](docs/training.md)). |
| `settings.py` | Every env var and Application Support path. |
| `lifecycle.py` | Process group, leaving with the app, logging, `serve()`. |

### Providers (`providers/`)

`anthropic` · `openai` · `openai_compatible` (OpenAI at a custom `base_url` —
OpenRouter, Groq, or a local Ollama / LM Studio at `http://localhost:11434/v1`)
· `gemini` · `local` (on-device). Each supports streaming, images and prior-turn
history; native OpenAI gets `max_completion_tokens`, compatible servers
`max_tokens`.

---

## Adding things

**A provider** — create `providers/<name>.py` with a class that has `name`,
`requires_key`, `label(base_url)`, `chat`, `stream`, `list_models`,
`transcribe_audio` (see `providers/base.py`; raise `ValueError` for anything it
can't do), then add one instance to `default_registry()` in
`providers/registry.py`. Routes, NDJSON framing and error mapping need nothing.
The app side needs the provider in its own catalog.

**A route** — add it to the area's router in `api/routes/` (or a new module
listed in `routes.routers()`), its body to `api/schemas.py`, and take
`services: ServicesDep` for anything stateful. Raise `flowy.errors` types
(`BadRequest`, `NotFound`, …) or wrap a provider call in
`upstream_errors("…")`; return a plain dict. Test it through
`create_app(Settings.from_env({}), Services(fakes…))` like
`tests/test_http_api.py`.

**A job type** — make a dataclass with `id` and `state`, a module-level
`JobRunner(active_states=…, persist=…)`, start work with `runner.spawn(...)`
and record progress with `runner.update(...)`/`mutate(...)`. Expose `busy()` and
add it to `Services.busy()` so `/health` keeps the server alive while it runs.

---

## Config

| Env var | Effect |
|---|---|
| `SLIVE_PARENT_PID` | The app's pid — the server exits when the app dies. |
| `SLIVE_PROCESS_GROUP=1` | Lead a process group (the app stops it as one unit). |
| `SLIVE_TRAINING_DIR` | Training store (default `~/Library/Application Support/Slive/training`). |
| `SLIVE_TRAINING_OUTPUT_DIR` | Fine-tuning runs (default `…/Slive/training-runs`). |
| `SLIVE_CUSTOM_MODELS_DIR` | Installed fine-tuned models (default `…/Slive/Models/Custom`). |
| `SLIVE_WHISPERKIT_TOOLS` | whisperkittools venv + shim (default `…/Slive/tools/whisperkittools`). |
| `WHISPERKIT_GENERATE_MODEL` | Explicit WhisperKit converter executable. |

### Prompts (`prompts/`)

Drop a `.md`/`.txt` file here and it appears in the app's Settings → Assistant →
Prompt picker; its contents become the system prompt. Ships with `assistant.md`,
`rewrite.md`, `email-reply.md`.

---

## Whisper training

[`docs/training.md`](docs/training.md) covers the training store, `flowy-train`
(inspect the store, build a manifest) and the fine-tuning pipeline.
