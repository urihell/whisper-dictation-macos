
## Voice Processing (VPIO) audio capture — discrete channel layout (2026-06-09)
- `AVAudioInputNode.setVoiceProcessingEnabled(true)` makes the node present a
  **discrete multichannel** layout (observed: 9 identical channels @ 48 kHz,
  layoutTag = kAudioChannelLayoutTag_DiscreteInOrder / 0x930009).
- **`AVAudioConverter` cannot downmix a DISCRETE layout to mono — it silently
  outputs all zeros** (no error thrown). Symptom: capture "looks" alive (engine
  starts, buffers/frames flow) but downstream sees silence.
- Also: `AVAudioFormat(commonFormat:sampleRate:channels:interleaved:)` returns
  **nil for >2 channels** (no layout) — don't reconstruct VP formats that way.
- **Fix:** the discrete channels are duplicates each carrying the full signal —
  extract **channel 0** into a standard mono buffer, then resample mono→target
  (unity gain, a layout the converter handles).
- **Debugging lesson:** when validating an audio pipeline, measure sample
  **VALUES (RMS/peak), not frame COUNTS.** Three repros "passed" on frame count
  while every sample was 0.0. Count ≠ signal.
- **Evidence lesson:** this app's `Log` writes to **stderr**, redacted to
  `<private>` in the unified log. `open App.app` discards stderr. To see real
  logs, launch the installed binary directly:
  `nohup /Applications/App.app/Contents/MacOS/App >/tmp/log 2>&1 &`

## Cold-start first-word loss — make the "go" cue honest (2026-06-11)
- A COLD VPIO engine takes **~800ms to converge** and deliver its first buffer;
  it produces ZERO samples until then. Any "speak now" signal (chime, HUD) fired
  before that loses the leading word into the dead-zone.
- The warm-mic feature only protects sessions that ADOPT a flowing engine. The
  cold path (first launch, or after the warm window expires) was still exposed.
  Repro: warm window elapsed → cold start → "I need to go..." dropped the "I".
- **You can't recover un-captured audio** — key-down IS the cold start. The fix
  is to **delay the user-facing "go" cue until the mic is actually capturing**,
  not to try to reclaim lost samples.
- **Pattern:** in `StreamingTranscriber.start()`, after spawning the stream task,
  poll `audioProcessor.audioSamples` until non-empty (first buffer), with a ~2s
  timeout backstop (fail-open so a dead/denied mic degrades to old behavior) and
  a `sessionToken` check (clean cancel/Escape bail). Gate this on the VPIO path
  only — Bluetooth/non-VPIO capture is already instant. Then in the controller,
  fire the chime + `.recording` AFTER `start()` returns; keep `.preparing` + HUD
  up front for visual feedback during the wait. Warm adopt delivers in ~100ms so
  no regression there. Verified live: leading "I" survives every cold start.
- **Separate finding:** a SwiftUI/AttributeGraph teardown segfault (EXC_BAD_ACCESS
  in `DynamicViewListItem`/`DynamicContainer._ItemInfo` during `ViewGraphHost.
  tearDown`) surfaced after a `cancel()`/Escape. Stack is 100% Apple framework
  code — no app symbols — NOT caused by the cold-start fix. See full
  investigation below.

## VPIO is optional — never let its init failure kill the session (2026-06-16)
- **Symptom:** error toast `com.apple.coreaudio.avfaudio error -10875` when starting
  dictation right after switching the input device (AirPods → built-in mic) while
  the AirPods were contended by another device (phone playing video).
- **-10875 = `kAudioUnitErr_FailedInitialization`** (AUComponent.h), NOT a format
  error (-10868 is FormatNotSupported, -10863 CannotDoInCurrentContext). The VPIO
  audio unit failed to *initialize* — common while CoreAudio is still reconfiguring
  after a device switch.
- **Root cause:** `SelectableInputAudioProcessor.startRecordingLive` (and
  `resumeRecordingLive`) called `try startIsolatedRecording(...)` with NO fallback.
  VPIO is only an enhancement (the way macOS Mic-Mode isolation reaches a built-in
  mic) — `shouldEngageVoiceProcessing` returns true for built-in/wired, false for
  Bluetooth. When `setVoiceProcessingEnabled(true)` + `engine.start()` threw, the
  error bubbled startStreamTranscription → streamTask → onStreamError → fail() and
  killed the session.
- **Fix:** wrap the isolated-start in do/catch; on failure `teardownIsolationEngine()`,
  set `voiceIsolationEnabled = false` (so stop/resume reflect real state), and fall
  back to `inner.startRecordingLive` (plain capture). Dictation degrades gracefully
  instead of erroring. The code already tolerated VPIO *device-pinning* failing — it
  just didn't tolerate VPIO *starting* failing.
- **Lesson:** any optional audio enhancement (VPIO, noise reduction, device pinning)
  must fail OPEN to the proven plain path, never propagate as a fatal session error.

## Reinstall corrupts mic TCC grant → null format → uncatchable crash (2026-06-16)
- **Symptom chain:** after a reinstall + crash-cycling, every session captured
  ZERO audio ("No audio detected"), then the VPIO→plain fallback CRASHED with
  `required condition is false: IsFormatSampleRateAndChannelCountValid(format)`
  in `AVAudioNode installTapOnBus` (via WhisperKit `AudioProcessor.setupEngine`).
- **Root cause:** the reinstall (same bundle id, fresh self-signed signature) +
  hard `kill -9`/crash cycling left the app's **Microphone TCC grant corrupted** —
  System Settings *showed* it enabled, but the real grant was broken. Proof: a
  standalone Swift probe got `48000/1` + live audio (peak 0.036) while the APP's
  input node reported `0 Hz / 0 ch`. `tccutil reset Microphone <bundleid>` cleared
  it (reported clearing 4 duplicate records — confirming corruption) and a fresh
  grant fixed capture immediately.
- **Diagnosis lesson:** when an app gets a null/0 input format but a standalone
  process gets live audio, it's a per-app TCC grant problem, NOT hardware or
  coreaudiod. `tccutil reset Microphone com.udabby.WhisperDictation` (no sudo) is
  the reset; the multi-line "Successfully reset" output = stale duplicate entries.
- **Two code defects this exposed (both fixed):**
  1. **Uncatchable crash:** `installTapOnBus` with a 0/0 format raises an Obj-C
     `NSException` that Swift `do/catch` CANNOT intercept → hard SIGTERM. WhisperKit's
     `setupEngine` reads `inputNode.outputFormat(forBus:0)` and taps with it, no
     guard. Can't override it, so **pre-flight the same format on a throwaway
     `AVAudioEngine` and throw a catchable `WhisperError` first** (`assertInputFormatUsable`).
     Now surfaces as a toast via onStreamError instead of crashing.
  2. **No explicit mic request:** the app relied on WhisperKit's AVAudioEngine to
     implicitly trigger the TCC prompt — it doesn't reliably, which is what left the
     grant fragile. Fix: `AVCaptureDevice.requestAccess(for: .audio)` at launch in
     AppDelegate so the prompt fires once and the grant is well-defined.
- **VPIO-delivers-no-frames self-heal:** a stale coreaudio VPIO aggregate can
  "start" cleanly yet deliver zero frames. `waitForFirstCapturedBuffer` now returns
  Bool; on a VPIO-path timeout, tear down the dead engine, disable VPIO, and relaunch
  the streamer on plain capture within the same session (extracted `launchStreamer`).
- **Install hygiene lesson:** prefer `osascript -e 'quit app "X"'` over `kill -9` for
  the running app during dev installs — hard-killing while VPIO is warm leaves stale
  coreaudio aggregates AND can corrupt the TCC grant. `strings` misses em-dash (—)
  strings; use `strings -a` and grep a plain ASCII substring to verify new code.

## Settings device-list crash while mic warm — use-after-free + .onAppear re-entrancy (2026-06-16)
- **Symptom:** opening Settings (Audio tab) while the mic was WARM crashed with
  EXC_BAD_ACCESS in `objc_retain` (addr 0x20). Stack: `SettingsView.reloadAudioDevices()`
  ← `_AppearanceActionModifier` (.onAppear) ← `NSHostingView.layout()`. App frame
  present — a REAL app bug, NOT the 2026-06-11 framework-teardown crash (which had
  zero app frames).
- **Two compounding causes:**
  1. **Use-after-free:** `reloadAudioDevices` called WhisperKit's
     `AudioProcessor.getAudioDevices()`, which returned device objects whose name
     backing could be freed mid-enumeration. With the mic warm, the VPIO engine
     holds a transient CoreAudio AGGREGATE device that's created/torn down in the
     background — enumerating across that churn over-released a device name.
  2. **Re-entrancy:** `.onAppear` runs DURING `NSHostingView.layout()`; mutating
     `@State` (`audioDevices = …`) synchronously there re-enters the view update.
- **Fix:** (a) own the enumeration — added
  `SelectableInputAudioProcessor.connectedInputDevices()` using CoreAudio HAL
  (`kAudioHardwarePropertyDevices` + input-scope `kAudioDevicePropertyStreams`
  filter), copying UID + name into Swift `String`s so NO live CF reference escapes;
  (b) hop the @State write to the next main turn (`Task { @MainActor }`) so layout
  finishes first. Verified: no crash opening Settings / Refresh devices while warm.
- **Lesson:** never mutate SwiftUI @State synchronously inside `.onAppear`/appearance
  actions (they run mid-layout) — defer one main-actor turn. And when reading
  CoreAudio device properties, copy CFString → Swift String immediately; don't hold
  vendor-returned device objects, especially while a VPIO aggregate may be churning.

## SwiftUI/AttributeGraph teardown crash — investigation (2026-06-11)
- **Two crashes, NOT identical** (corrected an earlier wrong claim):
  - 6/11: EXC_BAD_ACCESS / SIGSEGV at addr 0xfffffffffffffff0 (-16) on the MAIN
    thread. Over-release signature. Stack: runloop → CoreAnimation txn commit →
    autorelease pool drain → `ViewGraphHost.tearDown` → `GraphHost.invalidate` →
    `DynamicContainerInfo`/`DynamicViewListItem` destroy → `swift_arrayDestroy`.
  - 6/10: EXC_BREAKPOINT / SIGTRAP on a BACKGROUND dispatch thread, in
    `AG::LayoutDescriptor::make_layout` / `TypeDescriptorCache::fetch`.
  - Same subsystem (AttributeGraph), different phase/thread/signal. Both 100%
    Apple-framework — zero app frames in the fault.
- **Key structural fact:** `OverlayController.hide()` only calls `orderOut` and
  KEEPS the HUD panel + its `NSHostingView` alive — the HUD view graph is never
  torn down. So the crashing `ViewGraphHost.tearDown` is NOT the HUD. The graphs
  that DO tear down are the `MenuBarExtra` dropdown (every close) and the
  `Settings` window (on close). The crash's `DynamicViewListItem` matches a real
  `ForEach` — and `SettingsView` has several (audioDevices/models/vocab/replacements).
- **All `@Published`/observed-state holders are correctly main-confined** —
  audited `StreamingTranscriber` (@MainActor), `StatusController` (@MainActor,
  timer hops to main), `MicUsageMonitor` (CoreAudio listener → `Task{@MainActor}`).
  No off-main mutation of SwiftUI state found. Ruled out the usual cause.
- **Could NOT reproduce:** drove the menu-bar app via System Events —
  50+ Settings open→cycle-all-5-tabs→close cycles AND 60 menu open/close cycles
  = 110+ teardown cycles, ZERO crashes. So it is NOT a deterministic teardown
  bug; it's a rare race (real crashes were 2 in days of use), and the real ones
  coincided with an ACTIVE dictation (HUD `@ObservedObject` publishing ~8/sec)
  overlapping a graph teardown.
- **Conclusion:** most consistent with a macOS 26.5 SwiftUI/AttributeGraph
  framework over-release during view-graph teardown, not a pinpointable app line.
  Per systematic-debugging "no root cause" path: do NOT apply a speculative fix
  to framework-internal crashes. Documented + monitor for recurrence.
- **Repro-harness lesson:** `open -a App` on an ALREADY-running LSUIElement app
  does NOT open Settings (window count stayed 0) and `open -n` spawns a 2nd
  instance — both false negatives. The reliable drive is via System Events:
  `click menu bar item 1 of menu bar 2` → `click menu item "Settings…" of menu 1`.
  SwiftUI TabView tabs surface as `buttons of toolbar 1 of window 1` (NOT an AX
  tab group). ALWAYS verify the harness actually performed the action (assert
  window count > 0) before trusting a "no crash" result.
