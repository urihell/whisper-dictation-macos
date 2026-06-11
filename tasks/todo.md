# Task: Close cold-start first-word gap (honest "go" cue) — 2026-06-11

## Root cause (measured, builds on warm-mic work below)
The warm-mic feature only protects sessions that ADOPT a flowing engine. On a
COLD start (first launch, or after the warm window expires) `begin()` plays the
"go" chime and shows the HUD BEFORE the VPIO engine converges (~800ms, during
which the mic delivers ZERO samples). User hears "go", speaks, and the leading
word lands in the dead-zone. Reproduced live: warm window elapsed → cold start →
"I need to go to the grocery store" lost the "I".

## Fix (user-approved): make the "go" cue honest
Can't recover un-captured audio (key-down IS the cold start). Instead, don't
signal "speak now" until the mic is actually capturing.
- HUD shows "preparing…" instantly (visual feedback during the wait). [chosen]
- Chime + .recording fire only after the first captured buffer arrives.
- Warm path: first buffer in ~100ms → effectively instant (no regression).
- Cold path: chime ~800ms later, but no lost words.
- Bluetooth (non-VPIO) path: already instant, skip the wait.
- Scope: fully fixes toggle mode (user's mode) + first-launch. Push-to-talk
  still can't be fully fixed (already speaking while holding the key).

## Steps
- [x] StreamingTranscriber.start(): after spawning the stream task, on the VPIO
      path await first captured buffer (audioSamples non-empty), ~2s timeout
      backstop, honor sessionToken for clean cancel/Escape. Return only once live.
- [x] DictationController.begin(): keep setState(.preparing) + HUD show up front;
      move SoundFeedback.start() to fire with the .recording transition.
- [x] Build Debug → safe install → live verify: cold start captures leading word;
      warm start still instant.
- [x] Verify locally, then STOP (no commit/push — user's call).

## Review — DONE + VERIFIED LIVE (2026-06-11)
- Fix shipped: 2 files. StreamingTranscriber.start() now awaits the first
  captured buffer on the VPIO path (waitForFirstCapturedBuffer: 20ms poll, ~2s
  fail-open timeout, sessionToken-guarded). begin() holds the chime + .recording
  until start() returns; .preparing + HUD shown up front.
- Log proof: every path (cold start, warm adopt, warm-off) now shows
  `Mic live — first buffer captured.` BEFORE `begin() — now recording`. Warm
  adopt clears instantly; cold start clears after VPIO converges.
- USER-CONFIRMED: leading "I" lands in every cold-start dictation now.
- NOT committed/pushed (user's call). Working tree only.
- KNOWN UNRELATED ISSUE: SwiftUI/AttributeGraph teardown segfault after
  cancel()/Escape — pre-existing (same crash class on 6/10), 100% Apple-framework
  stack, not caused by this fix. Logged in lessons.md as a separate investigation.

---
# (prior) Task: Eliminate first-word loss via configurable mic warm-up

## Root cause (measured)
VPIO (`setVoiceProcessingEnabled(true)` + `engine.start()`) takes **~800ms** to
deliver its FIRST audio buffer (measured 785/786/822ms over 3 runs). Until then
the mic produces ZERO samples. Speaking immediately on key-down loses the first
word(s) into that dead-zone. Prewarm-on-key-down can't fix it — key-down IS the
cold start. Only keeping the engine warm (already flowing) BEFORE the press works:
once flowing, the next buffer arrives in ~100ms (tap interval), effectively instant.

## Design (user decisions)
- Setting: **"Microphone warm-up"** single picker in Settings → Audio.
  Options: Off / 30 seconds / 3 minutes (DEFAULT) / Always on.
- Off = tear down after each session (today's behavior, ~800ms each time).
- Timed = after a session ends, keep VPIO flowing for the window; next press
  adopts the warm engine instantly. Timer cancelled if a new session starts.
- Always on = never release while app runs (warmed lazily on first use; not
  primed at launch per user's "warm only after first use" intent → applies to
  timed modes; Always-on simply never tears down once warmed).
- Bluetooth path unaffected (no VPIO, already instant).
- Tradeoff accepted: mic-in-use indicator stays on during the warm window.

## Steps
- [ ] Remove TEMP INSTRUMENTATION (debugEngineStart/debugFirstBufferLogged + logs).
- [ ] AppSettings: add `MicWarmUp` enum (off/sec30/min3/always) + persisted prop,
      default .min3. Add Keys entry.
- [ ] SelectableInputAudioProcessor: add warm-idle mode.
      - `enterWarmIdle()`: detach callback, keep engine running, reset buffers;
        ingest keeps only a short rolling pre-roll (cap BOTH audioSamples and
        audioEnergy so neither grows unbounded while idle for minutes).
      - `startRecordingLive` adopts a warm-idle engine instantly (attach callback).
      - `fullyStop()`/hard release for Off mode + backstops.
- [ ] DictationController: on `setState(.idle)`, instead of unconditional
      forceStop, branch on setting: Off → forceStop now; timed → start/restart a
      warm timer that calls a hard release on expiry; Always → keep warm.
      Cancel timer on new begin(). Hard-release backstops: app terminate / resign,
      device change, errors.
- [ ] SettingsView: add the picker + caption in the Audio section.
- [ ] Build Debug → Release → safe install. Re-measure: first-word captured on
      a warm (2nd) dictation within the window; Off mode = old behavior.

## Review
DONE + VERIFIED LIVE.
- Warm-window feature shipped (MicWarmUp: off/15s/30s default/3min/always).
- Default 30s (short enough to rarely overlap a later call where VPIO echo
  cancellation could interfere; long enough to keep rapid dictations instant).
- Auto-release: MicUsageMonitor (macOS 14.4+, graceful fallback) watches
  kAudioHardwarePropertyProcessObjectList; releases the warm mic EARLY when a
  foreign process starts mic input — but ONLY while idle (between sessions),
  never mid-dictation. Excludes own PID + coreaudiod (verified live: our VPIO
  engine did NOT false-fire; foreign pid 988=corespeechd correctly triggered
  release; coreaudiod pid 428 correctly excluded).
- Two code reviews (warm-window race fix + monitor). Fixed: NSLock around shared
  buffer mutations (clear-vs-append race), settings-change re-arm, dead code,
  PID hardening (pid>0 && !mine && !coreaudiod).
- Live tested: warm→instant adopt, window-elapsed release, foreign-app release.
- NOT yet committed/pushed; DMG not yet rebuilt.

Caveat noted to user: detection fires on ANY foreign mic user incl. system
audio daemons (corespeechd), not just call apps — conservative/safe direction.
