# Flowy

**Hold a key, speak, release — Flowy transcribes your voice locally and types the
text straight into whatever app you're focused on.** A push-to-talk dictation
tool for macOS. Everything runs on your Mac; nothing is sent to the cloud.

```
 hold your key ─▶ speak (live waveform) ─▶ release
        │
   transcribed locally (faster-whisper, on-device)
        │
   typed into the focused text field  ─or─  shown in a copy box
```

---

## Get started (one command)

**You need:** an Apple-Silicon Mac + an internet connection. That's it — the setup
script installs everything else (it even fetches Python for you).

```bash
git clone <your-repo-url> Flowy
cd Flowy
./setup.sh
```

`./setup.sh` downloads and sets up **everything**: Xcode Command Line Tools,
`lame` (via Homebrew), `uv` + Python + the backend dependencies, a stable signing
identity, the transcription model, then builds and installs **Flowy.app** to
`/Applications` and launches it.

**Then, one manual step** (macOS requires it — no app can skip it): in the Flowy
window, click **Grant** on each permission, then click **Relaunch**:

| Permission | Why | Required? |
|---|---|---|
| **Microphone** | record your voice | yes |
| **Input Monitoring** | detect your push-to-talk key | yes |
| **Accessibility** | type transcripts into text fields | optional (for auto-type) |

> Each permission only takes effect **after a relaunch** — that's a macOS quirk,
> not a bug. The window has a **Relaunch** button. If a toggle looks ON in System
> Settings but Flowy still shows it as not granted, see [Troubleshooting](#troubleshooting).

That's the whole setup. **Hold your key, speak, release — the text appears where
your cursor is.**

---

## Using it

- **Dictate:** hold your push-to-talk key (~0.3s), speak, release. A small waveform
  pill shows while you talk; then it transcribes and:
  - **types the text into the focused text field** (if Auto-insert is on and a
    field is focused) — works in native apps, browsers, VS Code / Electron,
    terminals; **never** types into password fields, or
  - **shows a copy box** (with a copy button) if nothing editable is focused.
- **Everything is saved** to an in-app **History** (last 24h) you can copy from later.
- Flowy lives in the **menu bar** (waveform icon) and the **Dock**; it launches at
  login if you enable that. **⌘Q** quits it and shuts its backend down.

---

## Settings

Open **Settings** from the menu-bar icon (or ⌘,). It's tabbed:

- **General** — pick your push-to-talk key (fn / Right ⌘ / Right ⌥ / Right ⌃),
  Launch at login, and **Auto-insert into text fields**.
- **Permissions** — live status + one-click Grant for Microphone, Input
  Monitoring, Accessibility, plus a Relaunch button.
- **Vocabulary** — teach it your words:
  - **Custom words** — names, jargon, acronyms (helps it spell them right).
  - **Context prompt** — a sentence of context to steer transcription.
- **History** — your recent transcripts (24h), each copyable/deletable.

The window is resizable and supports full screen.

---

## Privacy — it's fully local

- Audio and text **never leave your Mac.** The app only ever talks to
  `http://127.0.0.1:50711` — its own backend running on your machine.
- **Recordings aren't saved** — audio lives in a temp file only long enough to
  transcribe, then it's deleted.
- History + vocabulary live only in `~/Library/Application Support/Flowy/`.
- The **one** external contact is a one-time download of the ~75 MB speech model
  (from Hugging Face) on first run. After that it's 100% offline — you can pull
  the Wi-Fi and it still works.

---

## How it works

```
Flowy/
├── Frontend/   the macOS app (Swift/SwiftUI): overlay, hotkey, typing, settings
├── Backend/    local transcription server (Python: FastAPI + faster-whisper)
└── setup.sh    one-command bootstrap
```

The Swift app records your voice, sends the audio to its own Python backend on
`127.0.0.1:50711`, gets back text, and types it into the focused field. **The app
auto-starts and stops that backend for you** — you never run a server by hand.
Transcription uses `faster-whisper` locally today, behind a swappable seam where
**Gemma 4 E2B** slots in later.

---

## For developers

### Manual build (instead of `setup.sh`)

Prereqs: Command Line Tools (`swift`), `uv`, and `lame` (`brew install lame`).

```bash
cd Backend  && uv sync                 # create the venv the app auto-launches
cd ../Frontend && ./setup-signing.sh   # one-time: stable signing identity
./build.sh install                     # build, sign, install to /Applications
```

Nothing is hardcoded to one machine — `build.sh` bakes each checkout's own paths
at build time, so cloning anywhere works.

### Why the signing step

macOS ties permission grants to an app's **code signature**. Ad-hoc signing
changes every build, so macOS forgets your grants each time. `setup-signing.sh`
creates a stable **self-signed** identity ("Flowy Local Signing") so you grant
permissions **once** and they persist across rebuilds. (It's the free, local
equivalent of a paid Apple Developer ID — which you'd only need to *distribute*
the app to other Macs.) To undo: `security delete-identity -c "Flowy Local Signing"`.

### Backend directly (for debugging)

```bash
cd Backend
uv run python -m flowy.server    # serves POST /transcribe on :50711
uv run pytest -q                 # tests
```

Speed/accuracy: default model is `tiny.en` (~1.8s for a 7s clip on M4). For more
accuracy on heavy jargon, use a bigger model without rebuilding:

```bash
launchctl setenv FLOWY_WHISPER_MODEL base.en   # then Quit & reopen Flowy
```

### Security posture

- **Localhost-only networking**, **Hardened Runtime** (blocks code injection),
  **stable signature** (TCC only trusts *your* signed binary), secure/password
  fields are never written to, and a website can't reach these permissions.

---

## Troubleshooting

- **A permission won't turn green even though it's ON in System Settings.** macOS
  caches the check per app launch → **Quit & reopen Flowy** (or use the Relaunch
  button). If it *still* won't stick, the old grant is stale (from before the
  stable cert); reset it and re-grant fresh:
  ```bash
  tccutil reset Accessibility com.flowy.overlay     # or Microphone / ListenEvent
  ```
  then grant it again in the window and relaunch.
- **Auto-type doesn't land in a specific app.** It types via synthetic keystrokes,
  which works nearly everywhere; if an app refuses, use the copy box (it appears
  when no editable field is detected) or file it and we'll tune that case.
- **Transcription feels slow / stuck on the dots.** Make sure you relaunched after
  the last update (the fast model needs a backend restart). Backend log:
  `/tmp/flowy-backend.log`.
- **"still ad-hoc" after installing.** Run `./setup-signing.sh` first, then
  `./build.sh install` — it should print `Signing with stable identity`.

---

## Roadmap

- **Gemma 4 E2B** on-device, swapped in behind `transcribe()` (seam is ready).
- **Zero-dependency distribution** — a fully native on-device engine
  (WhisperKit / MLX-Swift) would delete the Python backend entirely, so the only
  requirement becomes "open the app."
- **Vocabulary that learns** — auto-collect your recurring words / corrections.
