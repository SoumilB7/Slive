# Slive Maximum-Efficiency Plan (efficiency-pass)

**Framing: the speed ⇄ resources graph.** Every element gets placed on a
Pareto frontier — maximum responsiveness vs minimum resources (CPU wakeups,
RAM residency, GPU surfaces, battery). Three buckets:

1. **Free wins** — moves that are faster AND cheaper (most findings; do first).
2. **True trade-offs** — points on the curve the USER should choose via a knob
   (model size, animation fidelity, typing pace), never accidents of code.
3. **Floors** — costs inherent to the product (event tap wakes on keystrokes,
   one resident model for instant dictation start). Named and accepted.

## Measured baseline (July 17, 2026 — pid 69211, uptime 4h11m)

| Metric | Value | Verdict |
|---|---|---|
| CPU time | 25:07 over 4h11m ≈ **10% sustained** | 🔴 far too high at idle — the #1 target |
| Physical footprint | **201MB** (peak 324MB) | 🟡 heap is only ~50MB; rest is surfaces+model |
| IOSurfaces | **33 surfaces, 52.5MB (46.7MB dirty)** | 🔴 suspicious accumulation (panel rebuilds?) |
| Sleep assertions | none from Slive | ✅ fixed earlier, verified live |
| Python backend | not running | ✅ lazy-start fix verified live |
| Models on disk | 891MB (App Support) + 75MB bundled | 🟡 disk only; RAM residency is what matters |
| Training data | 33MB | ✅ capped at 1GB by setting |
| App bundle | 83MB (binary 5MB) | ✅ fine |

## Live-system evidence (measured, not inferred)

1. **Audio IO thread alive at idle** (`com.apple.audio.IOThread.client` +
   `AUScheduledParameterRefresher` in a thread sample, hours after last
   dictation). Cause found: **FeedbackPlayer keeps a persistent output
   AVAudioEngine running forever** (FeedbackPlayer.swift:27 — "started once,
   reused") → ~86 silent render callbacks/sec 24/7, audio HAL never idles,
   and `coreaudiod` holds a BuiltInSpeakerDevice power assertion on our
   behalf (seen in `pmset -g assertions`). Cost: constant CPU + battery.
   Speed it buys (instant cue) is preservable for free:
   `engine.isAutoShutdownEnabled = true` or stop-after-linger.
2. **CA::Transaction commits on the main thread while every window is
   off-screen** — something re-renders invisibly (UI audit to pin exact view).
3. **33 IOSurfaces / 52.5MB** for only 7 windows (all off-screen) — includes
   the settings window kept alive after close (540×700 + full SwiftUI
   hierarchy), the always-hosted overlay panel, and four mystery 1470×33
   strips. Panel rebuilds on wake/unlock may be accumulating surfaces.
4. ANE service threads resident (model pipes) — expected while a model is
   kept hot (the "instant dictation" floor), but must be exactly ONE model
   unless continuous is enabled with a different one.

## Findings by layer

### Layer 1 — Audio capture & speech model (audited)

**Per-callback costs (recording, ~47 cb/sec at 48kHz/1024-frame tap):**
- AudioRecorder.handle: **~4 heap allocations per callback ON the audio render
  thread** (fresh AVAudioPCMBuffer :187, mono Array copy :221, bands array
  FFT:96, dispatch block :226) ≈ 188 allocs/sec + 47 WAV writes/sec + 47
  main-thread wakeups/sec. Audio-thread malloc can block on the allocator
  lock → dropout risk, not just CPU.
- FFT runs 1024-pt on ~341 real samples (zero-padded) 47×/sec.
- AudioModel: level dispatches only set non-@Published targets; a self-stopping
  60fps timer republishes → idle-clean ✅ but 60 redraws/sec while active, with
  a fresh [Float] alloc per tick.
- LiveTypist during a hold: re-arms every 30ms even when caught up; ~90
  no-op allocs/sec (Array(target)/prefix/committed per tick).

**RAM residency:**
- Model pipes = dominant RAM; evicted only on switch/quit — **no
  memory-pressure eviction** (no DispatchSource memoryPressure anywhere).
- WhisperKit live buffer `audioSamples`: **64KB/sec growth, purged only at
  session START** — 10-min hold ≈ 38MB + COW transients, AND the last hold's
  full audio **stays resident after release** until the next session.
  `audioEnergy` grows too (minor). Purge-on-stop is app-side doable.
- FFTProcessor reallocated every start(), never nil'd on stop().

**Continuous decode loop (the sustained-CPU shape):**
- Decode pass ~every ≥1s of new speech; each pass copies the ENTIRE growing
  buffer (`Array(currentBuffer)` — ~38MB memcpy/pass at 10min).
- clipTimestamps seeks past confirmed segments, so the re-decoded window is
  the trailing unconfirmed span — but one long unbroken utterance stretches
  it toward the 30s chunk cap: **up to a full 30s re-encode every ~1s**.
  That window, not ANE-vs-GPU, is the dominant sustained cost. ANE is the
  right backend for this loop (low sustained power).
- **Release path re-transcribes the WHOLE utterance from scratch**
  (transcribeSamples, no clipTimestamps) + full snapshot Array copy — a
  5-min hold pays a multi-minute decode ON RELEASE. Keeping confirmed
  streamed text + decoding only the unconfirmed tail = release latency <1s.

**Ranked (audio):** 1) bound release re-decode to unconfirmed tail (huge
release-latency win, app-side); 2) purge audioSamples on stop (frees up to
~38MB idle, app-side, low risk); 3) preallocated tap buffers (removes ~140
allocs/sec from RT thread); 4) coalesce level dispatch 47→~15 wakeups/sec;
5) memory-pressure pipe eviction (hundreds of MB reclaimable; exclude live +
hotkey-enabled continuous model); 6) FFT rate/size halving; 7) reuse
FFTProcessor; 8) LiveTypist idle-tick backoff. Mid-hold buffer windowing
needs a WhisperKit fork (high risk) — defer/upstream.

### Layer 2 — UI & rendering (audited)

**Good news:** every animation loop is phase-gated (`paused:` bindings driven
by model.phase) and `hide()` call sites all pair with `model.reset()` — no
loop runs while the panel is hidden. This is by explicit state gating, not
TimelineView auto-pause — a strength, but an UNENFORCED invariant: one future
`hide()` without `reset()` breaks it silently. Fold `model.reset()` into
`OverlayController.hide()` to make it structural.

**Per-element rates & waste:**
- **BlackHoleOrbitView (assistant pill): UNCAPPED TimelineView(.animation) →
  120Hz on ProMotion**, ~12 Path + ~5 gradient allocations per frame ≈ 17k
  Path allocs/sec — and the halo/ring/core layers are geometrically constant
  every frame. Cap to 1/60 (one line, invisible change) + hoist statics.
- **AudioModel dead publishes:** `glow`, `elapsed`, `liveTail` are @Published
  but read by NO view — 2+ dead objectWillChange fires per 60Hz tick
  invalidating the whole OverlayView body. Demote to plain vars.
- **PenScribbleView (60Hz while continuous):** constant `fade` Gradient +
  6 constant pen sub-paths rebuilt every frame (~420 allocs/sec) — only the
  context transform varies. Cache both.
- **Easing timer lingers:** after a result box appears, the 60Hz timer keeps
  publishing `levels` (which the box doesn't read) until glow decays —
  hundreds of ms of dead 60Hz invalidations per dictation. Stop it on
  phase .result/.transcribing.
- WaveformView (14 paths/frame @60Hz while listening): cheap, fine.
  LoadingDots capped 30Hz ✅. SpeedometerView event-driven ✅. Heartbeat 2s
  tolerant + visible-only ✅.
- **Settings window retained forever after first open** (window + full
  SwiftUI tree + singleton subscriptions). No frames while closed, but a
  permanent memory hold + body diffs when singletons publish. Optional:
  release on close (trades reopen latency + lost scroll state).

### Layer 3 — Lifecycle, timers, storage (audited)

**Timers at steady state:** healthTimer 2s/tol1 always-on (~0.5 wakeups/s);
history prune 600s; all others correctly scoped (overlay heartbeat, permissions
poll, preview ticker, AudioModel 60Hz self-stopping). BackendManager watchdog
is DEAD CODE (start() never called since lazy-backend change) — delete.

**The dominant idle cost, confirmed:** FeedbackPlayer starts its output
AVAudioEngine at init and NEVER stops it → real-time audio IO thread pulling
silence (~86+ wakeups/s) for the entire app lifetime after the first hold,
holding audio hardware out of idle (matches the live `coreaudiod` assertion +
IO thread found in sampling). Fix: lazy start in playActivation + stop via
scheduleBuffer completion handler after a short linger.

**CGEventTap hot path (every system-wide keystroke):** `targets` computed
array is rebuilt 1–2× PER EVENT (+filter array + closures) ≈ 40–60 transient
allocs/sec while typing at 120WPM — and in chord mode the tap is synchronous
IN FRONT of the user's own keystrokes. Fix: cache targets + modifier-only
subset, rebuilt only in hotkeysChanged. (A speed AND resource win.)

**Launch path (main thread):** reapOrphans does fork/exec pkill +
waitUntilExit SYNCHRONOUSLY; migrateOldDownloadsIfNeeded scans dirs on main;
refreshModelResidency pulls the model into RAM+ANE at launch even if the user
never dictates that session. First two → background queue. Model preload →
a knob (see trade-offs).

**Storage:** TrainingStore eagerly loads ALL sample rows + full directory
size scan at init, and is touched by the TOP-LEVEL SettingsView observer —
opening any Settings tab loads the whole capture index. HistoryStore is
hard-bounded (~400KB) ✅. typeOut is already well-chunked (84 events / 500
chars) ✅.

## The plan — walking to the Pareto frontier

### Phase 1 — Free wins (faster AND cheaper; no trade-off, do all)

| # | Change | Resource saving | Speed effect |
|---|---|---|---|
| 1 | FeedbackPlayer: lazy engine start + stop-after-linger (~2s) | kills the dominant idle cost: ~86 wakeups/s + audio HW idle + coreaudiod assertion | none (linger keeps bursts warm) |
| 2 | HotkeyMonitor: cache `targets`/modifier subset | 40–60 allocs/s out of the global input path | REDUCES latency on every user keystroke |
| 3 | Continuous release: decode only unconfirmed tail, keep streamed confirmed text | avoids full-utterance re-decode + ~19MB copy | release latency: minutes→<1s on long holds |
| 4 | Purge WhisperKit audioSamples+audioEnergy on stop | frees up to ~38MB lingering after each continuous hold | none |
| 5 | BlackHoleOrbit: cap 1/60 + hoist static halo/ring/core | halves assistant-pill frames on ProMotion; −17k Path allocs/s | invisible |
| 6 | Demote dead @Published (glow/elapsed/liveTail); stop easing timer on .result/.transcribing | removes 60Hz dead whole-body invalidations | none |
| 7 | PenScribble: cache fade gradient + pen glyph paths | −420 allocs/s while continuous | none |
| 8 | AudioRecorder tap: preallocated convert/mono/bands buffers; dispatch levels every 3rd cb | −140 allocs/s OFF the RT audio thread (dropout safety); 47→~15 main wakeups/s | none (60Hz easer interpolates) |
| 9 | Launch: pkill + migration scan off-main | jank-free launch | faster perceived launch |
| 10 | Fold model.reset() into OverlayController.hide() | makes the no-loop-while-hidden invariant structural | none |
| 11 | Delete dead watchdog; healthTimer 2s→10s; PermissionsModel tolerance | fewer wakeups; less dead code | none |
| 12 | TrainingStore: async size scan; observe only from Training tab; FFTProcessor reuse; LiveTypist idle-tick backoff | less RAM/churn | Settings opens faster |

### Phase 2 — True trade-offs → explicit knobs (user picks the point)

1. **Model residency** (the big RAM lever — tiny ~tens MB vs Balanced
   hundreds): today eager-at-launch. Options: (a) keep eager (instant first
   hold), (b) preload ~5s after launch (hides latency, still resident), (c)
   lazy until first hold (zero RAM until used; first hold pays ANE
   specialize). Recommend (b) as default. Plus: **memory-pressure eviction**
   (DispatchSource) of any pipe except the actively-used + hotkey-enabled
   continuous one — reclaims hundreds of MB under pressure, costs a reload.
2. **Settings window**: release on close (frees tree; loses scroll/tab state,
   reopen latency). Low priority — do only if RAM target demands.
3. **Battery-aware fidelity** (optional): on ProcessInfo.isLowPowerModeEnabled,
   drop waveform easer 60→30Hz.

### Phase 3 — Floors (inherent; named and accepted)

- Event tap wakes on every keystroke — IS the hold-to-talk product.
- One hot model for instant dictation start — product choice (knob above).
- 60Hz waveform while actively listening — the product's feel.
- WhisperKit mid-hold buffer growth + up-to-30s re-encode window — inside the
  vendored package; app-side fixes end at stop-purge + release-tail-decode.
  Long-term: upstream PR or fork (high risk, defer).

### Expected outcome (measurable)

| Metric | Now | After Phase 1 |
|---|---|---|
| Idle CPU (no dictation) | ~10% sustained | **<0.5%** |
| Idle wakeups | ~86+/s (audio IO) | **~0.1–0.5/s** |
| Idle footprint | 201MB | ~150MB (Phase 1) / ~40–60MB pre-first-use (Phase 2c) |
| Continuous release (5-min hold) | multi-minute decode | **<1s** |
| Keystroke overhead (all typing) | 1–2 array allocs/event in tap | ~0 |
| Post-hold lingering RAM | up to ~38MB | 0 |

### Verification protocol (rerun after each phase)

`ps -o time` delta over 10 idle minutes → ~0; `top -stats power` sample;
thread list must show NO com.apple.audio.IOThread.client at idle; vmmap
footprint; pmset -g assertions (no coreaudiod speaker assertion from us);
afinfo on a fresh recording (1ch/16k); `--self-test` 55/55; IOSurface count
stable across 5 lock/unlock cycles (also chases the 33-surface anomaly and
the four 1470×33 mystery windows).
