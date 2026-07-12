# Flowy

A hold-to-talk voice capture app for macOS, paired with a local speech backend
built on **Gemma 4 E2B**. Hold a key, speak, release — the audio is saved as an
MP3, ready for on-device transcription.

```
[ hold your key ~0.3s ]
        │
   AVAudioEngine (mic) ──► live waveform overlay
        │
   16 kHz mono MP3  ──►  /Audios/flowy-<timestamp>.mp3
        │
   Backend (Gemma 4 E2B)  ──►  transcription / translation
```

## Repository layout

| Folder | What it is |
|---|---|
| **`Frontend/`** | `Flowy.app` — the macOS hold-to-talk mic overlay (Swift/SwiftUI). |
| **`Backend/`** | Python transcription server. Has its own [README](Backend/README.md). |
| **`Audios/`** | Legacy output folder (recordings are no longer persisted — audio is sent to the backend from a temp file that's deleted after). |

Transcripts are kept in an in-app **history catalogue** (Settings ▸ History):
a bounded, self-pruning store — 24h TTL, max 200 entries, 2000 chars each —
persisted at `~/Library/Application Support/Flowy/history.json`.

## Developer setup (any Mac)

Nothing is hardcoded to one machine — `build.sh` bakes each checkout's own
paths at build time, so cloning anywhere just works:

```bash
git clone <repo> && cd Flowy
cd Backend  && uv sync --extra dev     # create the venv the app auto-launches
cd ../Frontend && ./build.sh install   # bakes THIS checkout's paths, installs to /Applications
```

Then grant Microphone + Input Monitoring once (see below). The app auto-starts
its own backend, so there's nothing else to run.

---

## Frontend — the Flowy app

A background menu-bar agent: it lives in the menu bar (top-right), launches at
login, and shows a small waveform pill just above the bottom of the screen while
you hold your push-to-talk key.

### Requirements

- macOS 14+ on Apple Silicon
- Swift toolchain (`swift --version`) — Command Line Tools is enough, no full Xcode
- `lame` (or `ffmpeg`) for MP3 encoding: `brew install lame`

### Build & run

```bash
cd Frontend
./build.sh run        # build + bundle + launch from build/
./build.sh install    # build + bundle + copy to /Applications + launch
```

`build.sh` compiles the Swift package, assembles `Flowy.app` (icon + Info.plist),
signs it, and (for `install`) copies it to `/Applications`.

### Permissions

macOS gates these behind its privacy system (TCC). You grant each **once** in the
home window (or System Settings); the app shows live status with Grant buttons.
Each takes effect after a relaunch (a "Relaunch" button is provided).

| Permission | Why | Required? |
|---|---|---|
| **Input Monitoring** | Detect your push-to-talk key globally (keyboard tap) | Yes |
| **Microphone** | Record your voice | Yes |
| **Accessibility** | Auto-insert transcripts into the focused text field | Optional (only for auto-paste) |

When **Auto-insert** is on (Settings ▸ General) and a text field is focused, the
transcript is pasted straight in; otherwise the copy box appears. Secure/password
fields are never written to. No Screen Recording; network is localhost-only.

### Persistent permissions (do this once) 🔑

**The problem:** macOS ties a permission grant to the app's *code signature*.
Plain ad-hoc signing produces a **new signature every rebuild**, so macOS forgets
the grant and re-asks each time.

**The fix:** a stable, self-signed code-signing identity. Sign every build the
same way → grant permissions once → they persist across all future rebuilds.
(This is the free, local equivalent of what shipping apps like Whispr Flow do
with a paid Apple Developer ID. The one-time grant itself is unavoidable — macOS
requires it of every app.)

```bash
cd Frontend
./setup-signing.sh    # one-time: creates the "Flowy Local Signing" identity in your login keychain
./build.sh install    # now signs with that identity (look for "Signing with stable identity")
```

Then grant Microphone + Input Monitoring **once** in the window that opens. Done —
future `./build.sh install` runs keep the same signature, so no more prompts.

`setup-signing.sh` is local-only: it generates a self-signed cert (not an Apple
Developer cert), scopes the key to `/usr/bin/codesign`, and imports it into your
login keychain. Uses OpenSSL's `-legacy` PKCS#12 cipher, which macOS Keychain
requires. To undo: `security delete-identity -c "Flowy Local Signing"`.

> For **distributing** the app to other machines you'd need an Apple Developer ID
> ($99/yr) + notarization. Not needed for personal use.

### Security posture

- **Network is localhost-only** — Flowy POSTs recorded audio to its own backend
  at `http://127.0.0.1:50711` for transcription. There is no other networking; it
  never sends audio or keystrokes off the machine.
- **Hardened Runtime** (`codesign --options runtime`) — blocks other local
  processes from injecting code into Flowy to ride its permissions.
- **Stable signature** — TCC only honors the grant for a binary carrying *your*
  signature, so a swapped/malicious binary won't inherit mic/keyboard access.
- A **website cannot** reach these permissions: web content is sandboxed from
  native apps and TCC.
- Input Monitoring is used only for modifier-key up/down; the mic records only
  while you hold the key.

### Using it

- **Hold your key** (~0.3s) → speak → **release**. The MP3 lands in `/Audios`.
- **Menu-bar waveform icon** → Settings…, Open Recordings Folder, Quit.
- **Settings window**: pick your push-to-talk key (fn / Right ⌘ / Right ⌥ /
  Right ⌃), see permission status, toggle launch-at-login.

### Tuning knobs

| What | Where |
|---|---|
| Hold-to-arm delay (default 0.3s) | `holdActivationDelay` in [AppDelegate.swift](Frontend/Sources/Flowy/AppDelegate.swift) |
| Bar sensitivity / log curve | `gain`, `logRange`, `shape` in [FFTProcessor.swift](Frontend/Sources/Flowy/Audio/FFTProcessor.swift) |
| Overlay size / position | [OverlayView.swift](Frontend/Sources/Flowy/Overlay/OverlayView.swift), [OverlayController.swift](Frontend/Sources/Flowy/Overlay/OverlayController.swift) |
| MP3 format (16 kHz mono 64 kbps) | [Mp3Encoder.swift](Frontend/Sources/Flowy/Audio/Mp3Encoder.swift) |

---

## Backend — local transcription server

Python project (managed with `uv`). Serves speech-to-text at
`127.0.0.1:50711` (`POST /transcribe`, MP3 bytes → `{"text": ...}`). Uses
faster-whisper for now, behind a swappable `transcribe()` — **Gemma 4 E2B slots
in here later**.

**Flowy starts and stops this backend automatically** — the Swift app launches
`Backend/.venv/bin/python -m flowy.server` on startup (reusing it if already up)
and shuts it down on quit. You don't run it by hand. First launch downloads the
whisper model (~150 MB, one time); server log at `/tmp/flowy-backend.log`.

Run it manually (optional, for debugging):

```bash
cd Backend
uv sync --extra dev              # install deps incl. dev tools
uv run python -m flowy.server    # start the server on :50711
uv run pytest -q                 # run tests
```

MP3s in `/Audios` (16 kHz mono) are exactly the format Gemma 4 E2B's audio tower
expects.
