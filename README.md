<div align="center">

# Slive

**Hold a key, speak, release — it's typed at your cursor, and it never left your Mac.**

*Your whisper, truly yours.*

![macOS](https://img.shields.io/badge/macOS-Apple%20Silicon-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white)
![Python](https://img.shields.io/badge/Python-3.12+-3776AB?logo=python&logoColor=white)
![ANE](https://img.shields.io/badge/inference-Neural%20Engine-5E5CE6)
![License](https://img.shields.io/badge/license-Apache--2.0-green)

</div>

```
 fn ▼ hold                                              release ▲
┌─────────┐  16 kHz mono   ┌────────────────┐  keystrokes  ┌───────────────┐
│   mic   │ ─────────────▶ │   WhisperKit   │ ───────────▶ │ wherever your │
└─────────┘                │ (Neural Engine)│              │   cursor is   │
                           └────────────────┘              └───────────────┘
```

## What it does

- **Dictate** — hold your key, speak, release. Words are typed straight into whatever app you're in. A second **continuous** mode streams text live while you hold.
- **Ask** — a second hotkey sends your question to the AI of your choice — Claude, GPT, Gemini, any OpenAI-compatible endpoint, or a **model running on this Mac** — and the answer streams into a floating box. Attach a screenshot, keep the thread going.
- **Learn your voice** — every dictation can become training data. Correct it with a ground-truth model, then **fine-tune any Whisper checkpoint on your own speech** — LoRA on-device, compiled for the Neural Engine, installed straight into the model picker.

Transcription is on-device. Local LLMs are on-device. Fine-tuning is on-device. The only bytes that leave this Mac are the ones you explicitly send to a cloud AI.

## Quick start

```bash
git clone https://github.com/SoumilB7/Slive.git
cd Slive
./setup.sh        # installs, builds, launches ☕
```

Then one manual step (macOS requires it): hit **Grant** on each permission in the Slive window, then **Relaunch**.

| Permission | Why |
|---|---|
| 🎤 Microphone | hear your voice |
| ⌨️ Input Monitoring | feel your key |
| ♿ Accessibility | type for you |

That's it. Hold your key, speak, release.

*(Using a cloud AI? Add a key once in Settings → Models. Running local? Download a model there instead — no key.)*

## The training loop

```
 dictate ──▶ capture (audio + what Slive wrote)
                │
                ▼
         ground truth ("what it should have been" — any audio-capable model,
                │        cloud or local Gemma)
                ▼
    LoRA fine-tune any Whisper checkpoint          loss + KL, live-charted
                │
                ▼
     merge → CoreML → Neural Engine → it's in your model picker
```

Gated so it only runs when the data is worth it: 50+ well-populated recordings and 5+ minutes of speech.

## Under the hood

Two pieces — a Swift app and a local Python server it manages for you:

| | | |
|---|---|---|
| **The Mac app** | Swift/SwiftUI · hotkeys, overlay, typing, on-device STT, settings | [`Frontend/README.md`](Frontend/README.md) |
| **The local server** | Python/FastAPI on `127.0.0.1` · AI proxy, local LLM inference, fine-tuning | [`Backend/README.md`](Backend/README.md) |

The module map — and where to plug in new code — lives in [`ARCHITECTURE.md`](ARCHITECTURE.md).

API keys live in the macOS Keychain, never on disk. The binary ships its own test suite: `Slive --self-test`.

## License

[Apache 2.0](LICENSE)
