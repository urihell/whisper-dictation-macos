# Plan: Whisper-Powered Voice Dictation App for macOS

## Context

An easy, multilingual dictation tool for macOS — hold (or toggle) a hotkey,
speak in any language, and have the transcribed text appear at your cursor in
whatever app is focused. Existing macOS dictation is limited and cloud-bound;
this tool runs **Whisper entirely on-device** for privacy, offline use, zero
cost, and strong multilingual accuracy.

Decisions locked in:
- **Engine:** local on-device Whisper (no cloud, no API key).
- **App form:** native Swift menu bar app (SwiftUI `MenuBarExtra`).
- **Trigger:** configurable — both push-to-talk (hold) and toggle (press/press).
- **Output:** auto-insert text at the cursor (with a clipboard copy as backup).

### Build environment
This session is on **macOS with Xcode 26 + XcodeGen installed**, so the app is
built and compile-verified here. The repo uses
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`project.yml`) so the Xcode
project is generated reproducibly without hand-writing a `.pbxproj`.

## Tech choices

| Concern | Choice | Why |
|---|---|---|
| Transcription | [WhisperKit](https://github.com/argmaxinc/WhisperKit) (SPM) | Core ML / Apple-Silicon optimized Whisper; auto language detection; downloads models from Hugging Face; multilingual `large-v3` recommended |
| Global hotkey | [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) (SPM) | User-recordable shortcuts + `onKeyDown`/`onKeyUp` → supports both toggle and push-to-talk; built-in recorder UI for Settings |
| Launch at login | [LaunchAtLogin-Modern](https://github.com/sindresorhus/LaunchAtLogin-Modern) (SPM) | One-line login-item toggle |
| Audio capture | `AVAudioEngine` (system) | Tap input node, resample to 16 kHz mono Float (Whisper's required format) |
| Text insertion | `NSPasteboard` + synthesized ⌘V via `CGEvent` | Most reliable cross-app insertion; save/restore prior clipboard |
| UI | SwiftUI `MenuBarExtra` + Settings `Scene` (macOS 14+) | Minimal, native menu bar app |
| Project gen | XcodeGen `project.yml` | Buildable without committing a fragile pbxproj |

Target: **macOS 14+ (Sonoma)**, Apple Silicon (Intel works on supported models, slower).

## Repo layout

This is a dedicated app repo (`whisper-dictation-macos`); the app lives at the
repo root:

```
.
├── project.yml                       # XcodeGen project definition
├── README.md                         # build + usage instructions
├── .gitignore                        # ignore generated .xcodeproj, build/, DerivedData
└── WhisperDictation/
    ├── App/
    │   ├── WhisperDictationApp.swift      # @main, MenuBarExtra + Settings scene
    │   └── AppDelegate.swift              # permissions bootstrap, hotkey wiring
    ├── Core/
    │   ├── AudioRecorder.swift            # AVAudioEngine capture → [Float] @16kHz
    │   ├── TranscriptionService.swift     # WhisperKit load + transcribe
    │   ├── TextInserter.swift             # clipboard + ⌘V injection
    │   ├── DictationController.swift      # orchestrates record→transcribe→insert
    │   └── HotkeyManager.swift            # KeyboardShortcuts toggle/PTT wiring
    ├── Settings/
    │   ├── SettingsView.swift             # tabs: General, Model, Shortcut
    │   └── AppSettings.swift              # UserDefaults-backed prefs
    ├── UI/
    │   ├── MenuContent.swift              # menu bar dropdown (status, settings, quit)
    │   └── StatusController.swift         # menu bar icon state (idle/recording/working)
    └── Support/
        ├── Info.plist                     # LSUIElement=true, mic usage string
        └── WhisperDictation.entitlements  # mic; (sandbox off for ⌘V injection)
```

## Implementation steps

### 1. Project scaffolding
- `project.yml`: app target `WhisperDictation`, deployment macOS 14.0,
  SPM packages (WhisperKit, KeyboardShortcuts, LaunchAtLogin-Modern), Info.plist
  path, entitlements, `LSUIElement` = YES (menu-bar-only, no Dock icon).
- `Info.plist`: `NSMicrophoneUsageDescription`, `LSUIElement`.
- `README.md`: prerequisites (`brew install xcodegen`), generate + build steps,
  required permissions, first-run model download note.
- `.gitignore`: `*.xcodeproj/`, `build/`, `.DS_Store`, WhisperKit model cache.

### 2. Audio capture — `AudioRecorder.swift`
- Start/stop `AVAudioEngine`; install a tap on `inputNode`.
- Convert captured buffers to **16 kHz mono Float32** via `AVAudioConverter`
  (WhisperKit expects this). Accumulate into `[Float]`.
- Request mic permission via `AVCaptureDevice.requestAccess(for: .audio)`.

### 3. Transcription — `TranscriptionService.swift`
- Hold a `WhisperKit` instance; lazy-load the selected model on first use
  (first run pulls the model from HF).
- `transcribe(samples:language:)` using `DecodingOptions` (language = `nil` for
  auto-detect, or a forced ISO code; `task = .transcribe`). Trim special tokens.

### 4. Text insertion — `TextInserter.swift`
- Save current `NSPasteboard.general` contents, set our text, synthesize ⌘V with
  `CGEvent`, then restore the prior clipboard after a short delay.
- Gate on Accessibility trust: `AXIsProcessTrusted()`; if untrusted, call
  `AXIsProcessTrustedWithOptions` with the prompt option and show guidance.

### 5. Orchestration — `DictationController.swift`
- State machine: `idle → recording → transcribing → inserting → idle`.
- Drives recorder + service + inserter and publishes state to `StatusController`.
- Guards against overlapping sessions; handles empty/failed transcription.

### 6. Hotkey wiring — `HotkeyManager.swift` + `AppSettings.swift`
- Define `KeyboardShortcuts.Name.toggleDictation`.
- **Toggle mode:** `onKeyDown` flips begin/end.
- **Push-to-talk mode:** `onKeyDown` → begin, `onKeyUp` → end.
- Mode stored in `AppSettings`; handlers branch on current mode at call time.

### 7. UI — menu bar + settings
- `WhisperDictationApp.swift`: `MenuBarExtra` (icon reflects state) + `Settings` scene.
- `MenuContent.swift`: current status, Start/Stop Dictation, open Settings, Quit.
- `SettingsView.swift` tabs: General (trigger mode, launch at login, restore
  clipboard, language), Model (size picker), Shortcut (`KeyboardShortcuts.Recorder`).
- `StatusController.swift`: swap menu bar SF Symbol per state.

### 8. Permissions & first-run
- On launch, prompt for Accessibility; mic requested on first record.
- Default model: `base` with a note to upgrade to `large-v3` for best multilingual accuracy.

## Verification (runs on this Mac)
1. `brew install xcodegen && xcodegen generate`
2. `xcodebuild -scheme WhisperDictation -configuration Debug -destination 'platform=macOS' build`
   (compile check; `CODE_SIGNING_ALLOWED=NO` to skip signing).
3. `open WhisperDictation.xcodeproj`, select your team for signing, ⌘R to run.
4. Grant **Microphone** and **Accessibility** when prompted (System Settings →
   Privacy & Security → Accessibility → enable WhisperDictation).
5. In Settings, record a hotkey and pick a model (downloads on first use).
6. Focus a text field. Hold/press the hotkey, speak English, release/press again
   — confirm text inserts at the cursor.
7. Repeat with a non-English language (e.g. Hebrew/Spanish), language = Auto-detect.
8. Toggle between push-to-talk and toggle modes; verify both behave.
9. Confirm the clipboard is restored to its prior contents after insertion.

## Out of scope (future)
- Streaming/live partial transcription, custom vocabulary/prompts, punctuation
  post-processing, notarized signed release build / auto-update, Intel-Mac tuning.

## Risks / notes
- ⌘V injection requires Accessibility permission and disabling App Sandbox; this
  app is intended as a personal/unsigned local build, not the Mac App Store.
- First model download needs internet; transcription afterward is fully offline.
