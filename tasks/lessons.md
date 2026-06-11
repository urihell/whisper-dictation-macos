
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
  code — no app symbols — and a structurally identical crash predates this work
  (6/10). Treated as a pre-existing, unrelated bug, NOT caused by this fix.
