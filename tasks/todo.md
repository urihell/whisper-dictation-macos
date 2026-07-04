# Roadmap (as of 2026-07-02)

Prior task logs: see `archive-2026-06-warmup-coldstart.md` (mic warm-up +
cold-start first-word work, June 2026) and `lessons.md` (accumulated debugging
lessons — read before touching the audio path).

## Up next
- [x] Apple engine polish (1.11.0): asset pre-download from Settings/launch,
      HUD engine badge, experimental DictationTranscriber toggle.
- [x] Per-app overrides (1.11.0): language (also picks the engine), mic,
      press-Return, direct/clipboard — tri-state (nil = global), own
      "Apps" Settings tab. Warm-adopt now refuses cross-device adoption.
      Largely supersedes the per-hotkey-language idea.
- [x] App Intents / Shortcuts support — Toggle/Start/Stop (1.9.4), plus
      Dictate Text (capture-only, returns transcript) and Get Last
      Transcript (1.9.5).
- [x] Manual "Check for Updates…" menu item against the GitHub releases API
      (1.9.5) — stopgap until Sparkle (blocked on Developer ID).
- [ ] Per-hotkey forced language (e.g. one key = English, another = Hebrew)
      for deterministic bilingual dictation.
- [x] Apple SpeechAnalyzer engine option (macOS 26) — shipped in 1.10.0.
      Opt-in via Settings → Model → Engine; needs a fixed language (auto →
      Whisper); unsupported languages fall back to Whisper per session.
      Pairs with the per-hotkey-language item below.

## Blocked on Apple Developer ID ($99/yr — deliberately deferred)
- [ ] Developer ID signing + notarization. Ends the Gatekeeper "Open Anyway"
      dance AND makes TCC grants (Accessibility/Microphone) survive updates —
      ad-hoc signing re-prompts on every release.
- [ ] Sparkle auto-updates (not worth shipping while updates reset permissions).

## Watching
- [ ] AttributeGraph teardown crash (June 2026, lessons.md): no recurrence as
      of 2026-07-02 (zero crash reports on disk). AppDelegate now logs any new
      crash report at launch; high-rate publishers isolated to the HUD-only
      HUDLiveState to shrink the teardown-race surface. Revisit only if the
      launch check flags a report.

## Someday
- [ ] UI localization (the app transcribes 7 languages; its UI is English).
- [ ] Homebrew cask (best after notarization).
