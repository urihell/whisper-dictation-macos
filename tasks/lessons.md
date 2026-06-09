
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
