<div align="center">

# Slive

**Your whisper, truly yours.**

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

- **Dictate.** Hold your key, speak, release. Your words get typed right where your cursor is, in whatever app you're using. There's also a continuous mode that types live while you keep holding.
- **Ask.** A second hotkey sends your question to the AI you pick: Claude, GPT, Gemini, any OpenAI-compatible endpoint, or a model running right on this Mac. The answer streams into a small floating box. You can attach a screenshot and keep the conversation going.
- **Learn your voice.** Every dictation can become training data. Correct it with a ground-truth model, then fine-tune any Whisper checkpoint on your own speech. The training runs on your Mac, gets compiled for the Neural Engine, and lands straight in your model picker.

Transcription happens on your Mac. Local models run on your Mac. Fine-tuning happens on your Mac. The only bytes that ever leave are the ones you deliberately send to a cloud AI.

## Quick start

```bash
git clone https://github.com/SoumilB7/Slive.git
cd Slive
./setup.sh        # installs, builds, launches ☕
```

Then one manual step, because macOS insists: hit **Grant** on each permission in the Slive window, then **Relaunch**.

| Permission | Why |
|---|---|
| 🎤 Microphone | hear your voice |
| ⌨️ Input Monitoring | feel your key |
| ♿ Accessibility | type for you |

That's it. Hold your key, speak, release.

*(Using a cloud AI? Add a key once in Settings → Models. Running local? Download a model there instead. No key needed.)*

## The training loop

```
 dictate ──▶ capture (audio + what Slive wrote)
                │
                ▼
         ground truth ("what it should have been" from any model
                │        with ears, cloud or on-device)
                ▼
    LoRA fine-tune any Whisper checkpoint          loss + KL, live-charted
                │
                ▼
     merge → CoreML → Neural Engine → it's in your model picker
```

Training only unlocks when the data is actually worth it: 50 well-populated recordings and at least 5 minutes of real speech.

## Under the hood

Slive is two pieces. The app does everything you see and touch, and it quietly runs a small local server for the heavy model work.

| | | |
|---|---|---|
| **Slive App** | Swift/SwiftUI. Hotkeys, overlay, typing, on-device transcription, settings. | [`Frontend/README.md`](Frontend/README.md) |
| **Slive Server** | Python/FastAPI on `127.0.0.1`. AI relay, local LLM inference, fine-tuning. | [`Backend/README.md`](Backend/README.md) |

The module map, and where new code should plug in, lives in [`ARCHITECTURE.md`](ARCHITECTURE.md).

API keys live in the macOS Keychain, never on disk. The binary ships its own test suite: `Slive --self-test`.

## License

[Apache 2.0](LICENSE)
