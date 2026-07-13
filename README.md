<div align="center">

# 🎙️ Slive

A local, push-to-talk voice tool for macOS.
Your voice becomes text — or an AI answer — wherever your cursor is.

</div>

---

## What it does

**🎙️ Dictate** — hold your key, speak, release. Your words are typed straight into whatever app you're in.

**✨ Ask** — hold a *second* key and speak a question. It goes to the AI of your choice (Claude · GPT · Gemini · or a local model) and the answer **streams back** in a little floating box. Keep the thread going, or send a screenshot with it.

Transcription happens **on your Mac**. Nothing leaves it — unless you turn on the AI.

---

## Setup — about 2 minutes

```bash
git clone <your-repo-url> Slive
cd Slive
./setup.sh
```

`./setup.sh` installs everything, builds the app, and launches it. ☕

Then **one manual step** (macOS requires it): in the Slive window, hit **Grant** on each permission, then **Relaunch**.

| | |
|---|---|
| 🎤 **Microphone** | hear your voice |
| ⌨️ **Input Monitoring** | feel your key |
| ♿ **Accessibility** | type for you |

**That's it.** Hold your key, speak, release. →

*(Using the AI? Add an API key in Settings → Assistant, or point it at a local model.)*

---

## Under the hood

Slive is two pieces — a Mac app and a tiny local server it starts for you:

| | | |
|---|---|---|
| 🖥️ **The Mac app** | Swift · overlay, hotkeys, typing, settings | [`Frontend/README.md`](Frontend/README.md) |
| 🧠 **The local server** | Python · transcription + the AI plumbing | [`Backend/README.md`](Backend/README.md) |

Curious how it works, or want to change something? Those two READMEs have everything.
