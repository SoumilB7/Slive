# Slive App (Frontend)

The Swift/SwiftUI macOS app: it listens for your push-to-talk key, records your
voice, shows the floating overlay, and either **types the text** into the focused
app or **streams an AI answer** back. It also **auto-starts and stops the Python
backend** for you — you never run a server by hand.

> New here? The [top-level README](../README.md) is the 2-minute setup.
> This file is for understanding or changing the app.

---

## Build it yourself

`../setup.sh` does all of this for you. To do it by hand:

```bash
cd Backend  && uv sync              # the venv the app auto-launches (see ../Backend)
cd ../Frontend
./setup-signing.sh                  # one time: create the stable signing identity
./build.sh install                  # build → sign → copy to /Applications → launch
```

`./build.sh` also has `run` (launch from `build/`, don't install) and no-arg
(build + bundle only). Nothing is hardcoded to one machine — `build.sh` bakes
each checkout's own paths into `Info.plist` at build time.

**Requires:** Xcode Command Line Tools (`swift`). Swift 5 language mode, macOS 14+.

### Why the signing step

macOS ties permission grants (Microphone, Input Monitoring, Accessibility, Screen
Recording) to an app's **code signature**. Ad-hoc signing changes every build, so
macOS forgets your grants each time. `setup-signing.sh` makes a stable
**self-signed** identity — "Slive Local Signing" — so you grant permissions
**once** and they stick across rebuilds. It's the free local equivalent of a paid
Apple Developer ID (which you'd only need to *distribute* the app).
Undo with `security delete-identity -c "Slive Local Signing"`.

---

## The map

All source is under `Sources/Slive/`.

| Area | Files | What it does |
|---|---|---|
| **Orchestration** | `AppDelegate.swift`, `main.swift` | Ties everything together: key → record → transcribe → type **or** run the assistant; menu bar; the in-memory chat state. |
| **Hotkeys** | `Hotkey/Hotkey.swift`, `HotkeyMonitor.swift`, `HotkeyRecorderView.swift` | Two recordable shortcuts (dictate + assistant). A `CGEvent` tap that *listens* for modifier-only combos and *consumes* key chords so they don't leak. |
| **Audio in** | `Audio/AudioRecorder.swift`, `FFTProcessor.swift` | Mic capture to a WAV + live spectral levels for the waveform. |
| **Overlay** | `Overlay/OverlayController.swift`, `OverlayView.swift`, `AudioModel.swift`, `WaveformView.swift`, `BlackHoleOrbitView.swift` | The floating pill/box: dictation waveform, the assistant "black hole" listener, the streaming answer box + chat transcript, copy/dismiss/Continue. |
| **Assistant** | `Assistant/AssistantClient.swift`, `AssistantConfig.swift`, `KeychainStore.swift`, `PromptLibrary.swift`, `ScreenCapture.swift` | Talks to the backend's `/assistant`, `/assistant/stream`, `/models`. Provider/model/prompt config; **API keys live in the macOS Keychain**; optional full-screen screenshot; prompts read from `../Backend/prompts`. |
| **Typing** | `Paste/PasteEngine.swift` | Inserts text via synthetic keystrokes (works in native apps, browsers, Electron, terminals; never types into password fields). |
| **Transcription** | `Transcription/TranscriptionClient.swift` | POSTs the recorded audio to the backend, gets text back. |
| **Backend lifecycle** | `Backend/BackendManager.swift` | Spawns the Python server, health-watchdogs it, and kills it on ⌘Q — every launch runs fresh code. |
| **Feedback** | `Feedback/FeedbackPlayer.swift` | The subtle activation sounds (a tick for dictate, a "tung" for the assistant). |
| **Settings & state** | `Settings.swift`, `Overlay/SettingsView.swift`, `AssistantSettingsView.swift`, `PermissionsModel.swift` | Persisted prefs; the tabbed Settings window (Dictation section + Assistant section). |

---

## How it talks to the backend

The app never makes you run a server. `BackendManager` launches
`Backend/.venv/bin/python -m flowy.server` on `127.0.0.1:50711`, waits for
`/health`, and shuts it down on quit. Requests:

- **Dictation** → `POST /transcribe` (the recorded audio) → text → typed out.
- **Assistant** → `/transcribe` for the question, then `POST /assistant/stream`
  (provider + model + your key + optional screenshot + prior turns) → the answer
  streams into the box.
- **Model picker** → `POST /models` fetches the provider's live model list.

The provider/endpoint contract lives in [`../Backend/README.md`](../Backend/README.md).

---

## Permissions

Granted in the Slive window (Settings → Permissions), each takes effect only
**after a relaunch** (a macOS cache quirk, not a bug — there's a Relaunch button):

- **Microphone** — record your voice *(required)*
- **Input Monitoring** — detect a modifier-only push-to-talk key *(required)*
- **Accessibility** — type into text fields, and consume key-chord shortcuts *(needed for auto-type)*
- **Screen Recording** — only if you turn on "attach a screenshot" for the assistant

If a toggle looks ON in System Settings but Slive shows it as not granted, the
grant is stale — reset and re-grant:

```bash
tccutil reset Accessibility com.slive.app      # or Microphone / ListenEvent / ScreenCapture
```
