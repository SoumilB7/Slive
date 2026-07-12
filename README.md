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
| **`Backend/`** | Python speech backend (Gemma 4 E2B). Has its own [README](Backend/README.md). |
| **`Audios/`** | Where recordings are written (`.mp3`). Git-ignored contents. |

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

### Permissions (two, both required)

macOS gates these behind its privacy system (TCC). You grant each **once** in the
home window (or System Settings); the app shows live status with Grant buttons.

| Permission | Why | Asked |
|---|---|---|
| **Input Monitoring** | Detect your push-to-talk key globally (keyboard tap) | On launch / from Settings |
| **Microphone** | Record your voice | First recording |

No Screen Recording, no Accessibility, no network access.

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

- **No network code** — Flowy cannot send audio or keystrokes anywhere (verified:
  no `URLSession`/sockets/HTTP anywhere in the source).
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

## Backend — Gemma 4 E2B speech

Python project (managed with `uv`). See [Backend/README.md](Backend/README.md).

```bash
cd Backend
uv sync --extra dev      # install deps incl. dev tools
uv run pytest -q         # run tests
```

MP3s in `/Audios` (16 kHz mono) are exactly the format Gemma 4 E2B's audio tower
expects.
