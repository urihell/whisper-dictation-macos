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

## Download & install

1. **[Download the latest DMG](https://github.com/urihell/whisper-dictation-macos/releases/latest/download/WhisperDictation.dmg)**
   (Apple Silicon Mac, macOS 14 Sonoma or later).
2. Open the DMG and drag **Whisper Dictation** into **Applications**.
3. **First launch is blocked by Gatekeeper.** This app is open source but not
   notarized by Apple (a paid Developer account I've chosen not to buy), so
   macOS warns about an "unidentified developer." To open it anyway:
   - Try to open the app once (you'll get the warning — that's expected).
   - Go to **System Settings → Privacy & Security**, scroll down, and click
     **"Open Anyway"** next to the Whisper Dictation message, then confirm.
   - On **macOS 15 (Sequoia) and later** this is the *only* way — the old
     right-click → Open trick no longer works.
   - Power-user alternative: `xattr -cr "/Applications/WhisperDictation.app"`
     in Terminal, then open normally.
4. Grant **Microphone** (on first dictation) and **Accessibility**
   (System Settings → Privacy & Security → Accessibility — required to paste
   into other apps).
5. The first dictation downloads your chosen Whisper model (needs internet
   once); everything after that is offline.

> **Why does it need Accessibility?** Whisper Dictation inserts text by
> synthesizing a ⌘V keystroke into the focused app, which macOS gates behind
> Accessibility. If you'd rather not trust a pre-built binary with that access,
> the full source is in this repo — build it yourself (see below).

## First-run settings

Open **Settings** from the menu bar icon:

- **Shortcut** — record your dictation hotkey (push-to-talk or toggle).
- **Model** — pick a size (`base` is a good start; `large-v3` for best
  multilingual accuracy). Downloads on first use.
- **General** — trigger mode, language, launch at login.

Then focus any text field, trigger the hotkey, and speak.

## How it works

```
Hotkey ─▶ AudioRecorder (AVAudioEngine, 16 kHz mono)
       ─▶ TranscriptionService (WhisperKit)
       ─▶ TextInserter (NSPasteboard + synthesized ⌘V)
```

`DictationController` runs the state machine
(`idle → recording → transcribing → inserting → idle`) and publishes status to
the menu bar icon. The app runs **without the App Sandbox** because
synthesizing ⌘V into other apps requires Accessibility access, which sandboxed
apps cannot use — so it is not a Mac App Store app.

---

## For developers

### Requirements

- macOS 14 (Sonoma) or later — Apple Silicon recommended
- [Xcode](https://developer.apple.com/xcode/) 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

### Build & run

```bash
# Generate the Xcode project from project.yml (source of truth)
xcodegen generate

# Open and run (⌘R). Select your signing team in Signing & Capabilities first.
open WhisperDictation.xcodeproj
```

Or build headlessly:

```bash
xcodebuild -scheme WhisperDictation -configuration Debug \
  -destination 'platform=macOS' build
```

The generated `WhisperDictation.xcodeproj` is git-ignored; regenerate it with
`xcodegen generate`.

### Cutting a release

```bash
./scripts/build-dmg.sh        # → dist/WhisperDictation.dmg
gh release create vX.Y.Z dist/WhisperDictation.dmg \
  --title "vX.Y.Z" --notes "…"
```

`build-dmg.sh` produces an **ad-hoc-signed** DMG (no Apple Developer ID /
notarization), which is why recipients see the Gatekeeper step above. SwiftPM
dependencies are linked statically, so the app is self-contained and portable.
For a clean, warning-free install you'd need a paid Apple Developer ID plus a
`notarytool` step — not set up here.

## License

[MIT](LICENSE) © 2026 Uriel Dabby
