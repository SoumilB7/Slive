# Changelog

Notable changes to Slive, newest first. Versions follow [semver](https://semver.org).

## [0.2.0] - 2026-11-01

First release, in two downloads: **Slive** (on-device speech only) and **Slive Full** (with the Python server).

### Dictation
- Hold a key, speak, release: the words type wherever your cursor is. Whisper (large-v3 turbo and smaller) or Parakeet, all on the Neural Engine.
- Usable seconds after launch: dictation runs on Parakeet while Whisper compiles, then switches over.
- Dictations made while a model loads, or back to back, are queued and type in the order you spoke them.
- Custom words are spelled exactly as you typed them.
- Soft final words in a noisy room are no longer trimmed off.
- Pick the microphone; music on Bluetooth headphones stays in high quality while you dictate on the built-in mic.

### Live typing
- Types while you keep holding; Parakeet live decoding only re-reads the last few seconds, so long holds stay light.
- Stops typing if you switch apps mid-hold and offers the text to copy instead.

### Speed and battery
- Four speed tiers. Feather frees models only when macOS runs low on memory, and stops if reloads turn out slow on this Mac.

### Slive Full only
- Ask: send a question (and optionally a screenshot) to Claude, GPT, Gemini, OpenRouter or a local model; errors from the provider are shown instead of an empty box.
- Correct answers from a ground-truth model, with bad labels filtered out before training.
- Fine-tune Whisper on your own voice, on this Mac.
- The bundled server starts only when needed, stops after 10 idle minutes, and only answers Slive.

[0.2.0]: https://github.com/SoumilB7/Slive/releases/tag/v0.2.0
