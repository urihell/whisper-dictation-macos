# Whisper Dictation

A privacy-first, multilingual voice dictation app for macOS. Hold (or toggle) a
hotkey, speak in any language, and the transcribed text is inserted at your
cursor in whatever app is focused. Transcription runs **entirely on-device**
with [WhisperKit](https://github.com/argmaxinc/WhisperKit) — no cloud, no API
key, no per-use cost.

## Features

- 🎙️ **On-device Whisper** via Core ML (Apple Silicon optimized)
- 🌍 **Multilingual** with automatic language detection
- ⌨️ **Configurable hotkey** — push-to-talk (hold) or toggle (press/press)
- 📋 **Inserts at the cursor** in any app (clipboard restored afterward)
- 🪧 **Menu bar only** — no Dock icon, stays out of the way
- 🔒 **Fully offline** after the first model download

## Requirements

- macOS 14 (Sonoma) or later — Apple Silicon recommended
- [Xcode](https://developer.apple.com/xcode/) 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build & run

```bash
# Generate the Xcode project from project.yml
xcodegen generate

# Open and run (⌘R). Select your signing team in Signing & Capabilities first.
open WhisperDictation.xcodeproj
```

Or build headlessly:

```bash
xcodebuild -scheme WhisperDictation -configuration Debug \
  -destination 'platform=macOS' build
```

## First run

1. **Microphone** — granted on your first dictation.
2. **Accessibility** — required to paste into other apps. Grant it in
   **System Settings → Privacy & Security → Accessibility** (enable
   *Whisper Dictation*).
3. Open **Settings** from the menu bar:
   - **Shortcut** — record your dictation hotkey.
   - **Model** — pick a size (downloads on first use; `base` is a good start,
     `large-v3` for best multilingual accuracy).
   - **General** — trigger mode, language, launch at login.
4. Focus any text field, trigger the hotkey, and speak.

## How it works

```
Hotkey ─▶ AudioRecorder (AVAudioEngine, 16 kHz mono)
       ─▶ TranscriptionService (WhisperKit)
       ─▶ TextInserter (NSPasteboard + synthesized ⌘V)
```

`DictationController` runs the state machine
(`idle → recording → transcribing → inserting → idle`) and publishes status to
the menu bar icon.

## Building a distributable DMG

```bash
./scripts/build-dmg.sh        # → dist/WhisperDictation.dmg
```

This produces an **ad-hoc-signed** DMG (no Apple Developer ID / notarization).
It runs on other Macs, but because it isn't notarized, the first launch is
blocked by Gatekeeper. On the recipient's Mac:

1. Open the DMG and drag **Whisper Dictation** to **Applications**.
2. First launch is blocked — go to **System Settings → Privacy & Security →
   "Open Anyway"**, or run: `xattr -cr "/Applications/WhisperDictation.app"`.
3. Grant **Microphone** and **Accessibility** when prompted.
4. First dictation downloads the chosen model (needs internet once).

For a clean, warning-free install on any Mac you'd need a paid Apple Developer
ID and notarization — not set up here.

## Notes

- The app runs **without the App Sandbox** because synthesizing ⌘V into other
  apps requires Accessibility access, which sandboxed apps cannot use. It is
  intended as a personal, locally-built tool — not a Mac App Store app.
- The generated `WhisperDictation.xcodeproj` is git-ignored; regenerate it with
  `xcodegen generate`. `project.yml` is the source of truth.

## License

Personal project — no license granted yet.
