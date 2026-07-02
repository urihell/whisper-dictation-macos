# Whisper Dictation

[![CI](https://github.com/urihell/whisper-dictation-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/urihell/whisper-dictation-macos/actions/workflows/ci.yml)

A privacy-first, multilingual voice dictation app for macOS. Press (or hold) a
hotkey, speak in any language, and the transcribed text is typed at your cursor
in whatever app is focused. Transcription runs **entirely on-device** with
[WhisperKit](https://github.com/argmaxinc/WhisperKit) — no cloud, no API key, no
per-use cost.

## Features

- 🎙️ **On-device Whisper** via Core ML (Apple Silicon optimized)
- 🌍 **Multilingual** with automatic language detection or a forced language
- ⌨️ **Flexible trigger** — push-to-talk (hold), toggle (press/press), or
  double-tap a single key
- ✍️ **Types at the cursor** in any app — synthesized directly, so the text
  **never touches the clipboard** (a clipboard-paste fallback is available)
- 📖 **Custom vocabulary & replacements** so names, jargon, and acronyms come
  out right (vocabulary biases the final recognition pass at no speed cost)
- 🗣️ **Spoken punctuation & formatting** — "comma", "period", "new line" and
  friends, localized for English, Spanish, French, German, Portuguese, Hebrew,
  and Chinese
- 🧹 **Optional on-device cleanup** (remove filler & self-corrections) via Apple
  Intelligence — cleans in the background *while you speak*, so long dictations
  finish almost instantly; opt-in, off by default
- 📋 **Copy Last Transcript** — the menu keeps your most recent dictation (in
  memory only) in case an insertion goes astray
- ⚡ **Shortcuts & Siri** — Toggle/Start/Stop Dictation actions for the
  Shortcuts app, Stream Deck, or "Hey Siri, toggle dictation"
- 🪧 **Menu bar only** — no Dock icon, stays out of the way
- 🔒 **Fully offline** after the first model download — nothing leaves your Mac

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
   (System Settings → Privacy & Security → Accessibility — required to type into
   other apps). If access is missing, the menu-bar icon shows a ⚠️ and the menu
   offers a one-click **Enable Accessibility Access…** shortcut.
5. The first dictation downloads your chosen Whisper model (needs internet
   once); everything after that is offline.

> **Why does it need Accessibility?** Whisper Dictation types into the focused
> app by synthesizing key events, which macOS gates behind Accessibility. If
> you'd rather not trust a pre-built binary with that access, the full source is
> in this repo — build it yourself (see below).

## Privacy

Everything happens on your Mac. Audio is transcribed on-device by WhisperKit and
is never uploaded; the only network access is the one-time model download. By
default the transcript is typed directly into the target app, so it never lands
on the clipboard (and can't be picked up by clipboard-history tools); the
optional paste fallback marks its clipboard item as concealed/transient so
well-behaved clipboard managers skip it. Dictated text is never written to logs.

## First-run settings

Open **Settings** from the menu bar icon:

- **Shortcut** — record your dictation hotkey, or pick a single-key / double-tap
  trigger.
- **Model** — pick a size (`base` is a good start; `large-v3` / `large-v3 turbo`
  for best multilingual accuracy). Downloads on first use.
- **General** — trigger mode, language, "type directly vs. paste," press-Return-
  after-insert, optional cleanup, and launch at login.
- **Dictionary** — custom vocabulary terms and heard → corrected replacements.

Then focus any text field, trigger dictation, and speak.

## How it works

```
trigger ─▶ DictationController            (state machine + gesture handling)
        ─▶ StreamingTranscriber           (WhisperKit AudioStreamTranscriber, live)
        ─▶ SpeechCleaner                  (optional on-device LLM cleanup)
        ─▶ TextInserter                   (direct key synthesis, or clipboard paste)
```

`DictationController` runs the state machine
(`idle → preparing → recording → transcribing → cleaning → inserting → idle`),
publishing the live transcript to the floating HUD (`OverlayController` +
`DictationHUD`) and status to the menu bar (`StatusController`). The app runs
**without the App Sandbox** because synthesizing key events into other apps
requires Accessibility access, which sandboxed apps cannot use — so it is not a
Mac App Store app.

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
