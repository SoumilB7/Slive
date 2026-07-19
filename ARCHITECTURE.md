# Architecture

Two processes. The **Swift app** owns everything real-time and user-facing;
the **Python backend** (spawned lazily by the app on `127.0.0.1:50711`) owns
everything model-heavy. They speak plain JSON over localhost.

```
┌──────────────────────────── Slive.app (Swift) ────────────────────────────┐
│  Hotkey ──▶ Audio ──▶ Transcription (WhisperKit · ANE) ──▶ Paste          │
│     │                                                        ▲            │
│     └──▶ Assistant ── HTTP ──┐              Overlay / Settings UI         │
└──────────────────────────────┼────────────────────────────────────────────┘
                               ▼
┌───────────────────── flowy server (Python · lazy) ────────────────────────┐
│  /assistant[,/stream]  cloud providers + local_infer (transformers, MPS)  │
│  /transcribe_llm       ground truth        /local/*   HF cache + download │
│  /training/*           LoRA → merge → CoreML/ANE → install                │
└───────────────────────────────────────────────────────────────────────────┘
```

## Frontend — `Frontend/Sources/Slive/`

One SPM target; folders are the module boundaries. Put new code in the folder
that owns its *domain*, not near its caller.

| Folder | Owns | Plug in here when… |
|---|---|---|
| `Hotkey/` | the global event tap, chord matching, health polling | new shortcuts, key behaviors |
| `Audio/` | mic capture → canonical 16 kHz mono, levels, preview playback | anything that touches the tap or buffers |
| `Transcription/` | WhisperKit registry (stock + custom models), streaming | new STT engines, model management |
| `Dictation/` | continuous-mode session logic, stitched release | dictation behavior |
| `Paste/` | typing into the focused app, secure-field guard, paste box | how text lands |
| `Assistant/` | provider enum + HTTP client for `/assistant` | new providers (add a case, extend `wire`) |
| `Models/` | ProviderStore (keys, model lists), local-model client | provider/credential plumbing |
| `Training/` | capture store, ground-truth + training clients, diffing | training data & jobs |
| `Overlay/` | the floating pill/box: controller, views, animations | overlay states & visuals |
| `Settings/` | the settings window: shell, sidebar, one file per page, shared atoms | new pages (add a `SettingsPage` case + a view) |
| `Theme/` | `SliveTheme` design tokens, brand mark | colors, fonts, spacing — never inline these |
| `History/`, `Feedback/`, `Backend/` | transcript history · audio cues · server lifecycle | |

Root files: `AppDelegate` (wiring), `Settings` (persisted state; Keychain for
secrets), `SelfTest` (the suite behind `Slive --self-test` — extend it with
every pure-logic change; CI is a green 79+).

## Backend — `Backend/src/flowy/`

| Module | Owns |
|---|---|
| `server.py` | all routes; pydantic request models; errors → `{"error": …}` JSON |
| `assistant.py` | cloud providers (Anthropic/OpenAI/Gemini/compatible) + prompts |
| `local_infer.py` | on-device LLM inference (transformers/MPS, int8, RAM cap) |
| `local.py` | HF cache scan/download/delete |
| `training/` | `store.py` (data validation) · `models.py` (checkpoint catalog + profiles) · `pipeline.py` (LoRA→merge→ANE) · `jobs.py` (job state machine) |

New provider → branch in `assistant.py`. New training source → entry in
`training/models.py`. New route → `server.py`, thin, logic in its module.
Heavy imports stay lazy (inside functions) so an idle server stays tens of MB.

## Invariants (break these and things get weird)

- **Audio is canonical**: everything downstream of the mic tap is 16 kHz mono
  Float32. Convert at the tap, nowhere else.
- **Secrets live in the Keychain**, travel per-request, and are never logged
  or written to disk.
- **Synthetic keystrokes are marked** so the hotkey tap ignores Slive's own
  typing; the paste engine never types into secure fields.
- **One resident heavyweight at a time** (local LLM, training run) — evict
  before loading the next.
- **The backend is disposable**: the app may kill/respawn it at any moment;
  all durable state lives on disk (HF cache, training store, Models/Custom).
- **Training labels are never the model's own raw transcript.**

## Testing

- Swift: `swift build && .build/debug/Slive --self-test` (pure-logic suite in
  `SelfTest.swift` — no XCTest; CLT-only toolchain).
- Python: `cd Backend && uv run pytest`.
