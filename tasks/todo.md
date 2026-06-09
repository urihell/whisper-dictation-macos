# Voice Isolation (background-noise suppression) — Plan

**Goal:** Suppress background chatter/noise so Whisper sees mostly the near speaker, using Apple's on-device Voice Processing I/O (VPIO) — the engine behind macOS "Voice Isolation" mic mode. AEC + noise suppression + non-voice ducking. No model, on-device, ~free CPU.

**Decision (locked):** Canonical toggle in **Settings → Audio**; **quick toggle in the menu-bar dropdown**; **passive "isolation on" badge in the dictation HUD** (read-only — the HUD is a non-activating panel and must never take focus/clicks).

**Default:** OFF (opt-in). VPIO colors the signal + applies AGC; a net win in noisy rooms, mild loss in quiet ones — so the user opts in.

---

## Architecture decision

WhisperKit's `AudioProcessor.setupEngine()` creates the input node, enables nothing, installs its tap, and starts the engine — all in one internal call. VPIO must be enabled on the input node **before** the engine starts, so we can't slip in via the public API of the wrapped processor.

**Chosen: Approach A — our `SelectableInputAudioProcessor` owns the capture engine when isolation is on.** No WhisperKit fork. Verified the fields we must populate are public:
- `inner.audioSamples` (ContiguousArray<Float>) — read by `stop()` for the final/tail decode
- `inner.audioEnergy` / `relativeEnergy` — drives the HUD meter + WhisperKit's silence logic
- `inner.audioBufferCallback` — drives the streaming loop
- Public statics available: `resampleBuffer`, `convertBufferToArray`, `calculateRelativeEnergy`, `calculateEnergy`

When isolation is OFF, the decorator forwards to `inner.startRecordingLive` exactly as today (zero behavior change / zero risk to the default path).

---

## Tasks

### 1. Setting + state
- [ ] `AppSettings`: add `voiceIsolationEnabled: Bool` (`@Published`, UserDefaults key `voiceIsolation`, default `false`).

### 2. Capture path — `SelectableInputAudioProcessor`
- [ ] Add `var voiceIsolationEnabled = false` (set per-session from `AppSettings`, like `selectedDeviceID`).
- [ ] In `startRecordingLive`:
  - **isolation OFF** → forward to `inner.startRecordingLive` (unchanged).
  - **isolation ON** → build our own `AVAudioEngine`:
    - get `inputNode`; `try inputNode.setVoiceProcessingEnabled(true)`
    - device selection: see **Risk 1** — fall back to system-default mic if VPIO + explicit device conflict; surface that in the UI copy.
    - install tap → resample to 16 kHz (reuse `AudioProcessor.resampleBuffer` + `convertBufferToArray`) → append to `inner.audioSamples`, compute + append energy (mirror `processBuffer`), invoke `inner.audioBufferCallback`.
    - `engine.prepare()` / `engine.start()`; retain engine; reset `inner.audioSamples`/`audioEnergy` at start.
- [ ] `stopRecording`/`pauseRecording`: tear down our engine when we own it; else forward.
- [ ] Resume path mirrors start.

### 3. Wire into session — `StreamingTranscriber.start`
- [ ] Where `selectedDeviceID` is set on the processor, also set `proc.voiceIsolationEnabled = AppSettings.shared.voiceIsolationEnabled`.
- [ ] Expose current effective state for the HUD badge (e.g. published `voiceIsolationActive` mirrored from the active session).

### 4. Settings → Audio UI — `SettingsView.audio`
- [ ] `Toggle("Voice Isolation (suppress background noise)", isOn: $settings.voiceIsolationEnabled)`.
- [ ] Caption: on-device; best in noisy rooms; may slightly soften audio in quiet ones; **takes effect next dictation**; note device-selection caveat if Risk 1 holds.

### 5. Menu-bar quick toggle — `MenuContent`
- [ ] `Toggle("Voice Isolation", isOn:)` bound to `AppSettings.shared.voiceIsolationEnabled` (menu is already interactive — safe here).

### 6. HUD passive badge — `DictationHUD`
- [ ] Small SF Symbol (e.g. `waveform.badge.mic` / `mic.badge.xmark`-style) + subtle label when isolation active. Read-only, no hit-testing, doesn't disturb the level meter / non-activating panel.

### 7. Verify (per CLAUDE.md — prove it works)
- [ ] Build release, install per macOS app-deploy sequence (kill → rm → cp → open; never cp over running app).
- [ ] A/B against real mic: (a) quiet room — confirm accuracy not degraded; (b) background chatter/music — confirm suppression win.
- [ ] Confirm default-OFF path is byte-for-byte the old behavior (forwarded to `inner`).
- [ ] Confirm HUD badge appears only when active; menu toggle + Settings toggle stay in sync.
- [ ] Bump version (currently 1.6.1) in `project.yml`.

---

## Risks / open questions
1. **VPIO vs. explicit input-device selection.** VPIO manages its own aggregate device; forcing a specific Core Audio input via the audio unit may be ignored or error. Plan: try device assignment, catch/fall back to system default, and state the limitation in UI copy ("Voice Isolation uses the system default microphone"). *Validate empirically during build.*
2. **Format/AGC coloring.** Expected; mitigated by opt-in default. The A/B test is the gate.
3. **First-session start cost.** VPIO renegotiates the input format → tens of ms one-time per session. Acceptable; confirm no perceptible stall.
4. **Energy bookkeeping fidelity.** Our replicated `processBuffer` math must match closely enough that the meter + silence/VAD logic behave. Mirror the exact relative-energy calc.

## Review

**Status: built, installed (v1.7.0), running. Awaiting your A/B mic test.**

Implemented all 6 steps:
1. `AppSettings.voiceIsolationEnabled` (UserDefaults `voiceIsolation`, default false). ✅
2. `SelectableInputAudioProcessor` — when on, owns its own `AVAudioEngine` with
   `setVoiceProcessingEnabled(true)`, resamples to 16 kHz, and mirrors WhisperKit's
   `processBuffer` math into `inner`'s public buffers. When off, forwards to `inner`
   unchanged (default path byte-for-byte the old behavior). ✅
3. `StreamingTranscriber.start` sets the flag per session + publishes
   `voiceIsolationActive`; cleared in `stop()`/`forceStop()`. ✅
4. Settings → Audio toggle + caption (notes noisy-room win / quiet-room caveat /
   system-default-mic caveat / next-dictation timing). ✅
5. Menu-bar dropdown quick toggle (interactive surface — safe). ✅
6. HUD passive badge (`waveform.badge.mic`, brand color, read-only, help text). ✅

Verified so far:
- Debug + Release builds succeed, no errors. ✅
- Installed per macOS sequence (kill → rm → cp → open). ✅
- `strings` confirms new symbols in the installed binary. ✅
- Clean launch, no errors in unified log. ✅
- Mic entitlement (`device.audio-input`) + `NSMicrophoneUsageDescription` already
  present — VPIO needs no new entitlement. ✅

### BUG FIX (round 2) — "no audio captured when isolation on"

**Root cause (found via standalone repro, not guessing):** Voice Processing
presents the input node as a **multichannel** format (measured: 9 channels @ 48 kHz).
My code rebuilt the tap/converter format with
`AVAudioFormat(commonFormat:sampleRate:channels:interleaved:)`, which **returns
nil for >2 channels** (no AVAudioChannelLayout). The `guard` then failed → we
threw before `engine.start()` → zero audio. The badge still showed because
`voiceIsolationActive` is set before the throw. (This is why WhisperKit's
identical reconstruction works without VP: a plain mic is ≤2ch.)

**Fix:** use the input node's OWN `outputFormat(forBus:0)` object (carries a valid
layout) for both converter and tap — never reconstruct it. Repro proved
`AVAudioConverter` downmixes 9ch→16kHz mono cleanly (30,197 frames/2s, 0 errors).
Rebuilt, reinstalled v1.7.0, verified in binary. ✅

### BUG FIX (round 3, ACTUAL root cause) — "no audio captured"

Round-2 format fix was necessary but not sufficient. Captured the app's real
stderr (launched the installed binary directly — `open` discards stderr, unified
log redacts to `<private>`) and saw the true signature:
`VAD everSpeech=false, top=music, maxSpeechConf=0.01, suppress=true → 0 chars`.

**Root cause:** Voice Processing presents a **discrete 9-channel layout**
(layoutTag kAudioChannelLayoutTag_DiscreteInOrder). `AVAudioConverter` **cannot
downmix a discrete layout to mono — it silently outputs all zeros.** Whisper got
pure silence → classified as music → my suppression logic dropped it. (My 3
earlier repros "passed" only because I counted sample *frames*, never *values*.)

**Fix:** the 9 channels are identical duplicates each carrying the full signal —
extract **channel 0** into a mono buffer, then resample mono→16 kHz (unity gain,
a layout the converter handles). Verified in isolation, then **confirmed live**:
3 sessions, `everSpeech=true, maxSpeechConf=0.92–0.94, top=speech, suppress=false`,
transcripts 15 & 77 chars typed in. ✅ Lessons recorded in lessons.md.

**Open — needs you:**
- [ ] A/B test: quiet room (confirm accuracy not degraded) vs. background
      chatter/music (confirm suppression win). Toggle via menu-bar dropdown.
- [ ] Confirm HUD badge appears only when isolation is on, and the menu/Settings
      toggles stay in sync.
- [ ] **Risk 1 validation:** with Voice Isolation ON *and* a specific (non-default)
      input device selected, confirm capture still works (we fall back to system
      default + log "couldn't pin input device"). Check Console for that line.

Not yet done (your call):
- [ ] Commit (working tree currently has the feature + version bump).
