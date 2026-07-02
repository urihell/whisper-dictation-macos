# Roadmap (as of 2026-07-02)

Prior task logs: see `archive-2026-06-warmup-coldstart.md` (mic warm-up +
cold-start first-word work, June 2026) and `lessons.md` (accumulated debugging
lessons — read before touching the audio path).

## Up next
- [x] App Intents / Shortcuts support — Toggle/Start/Stop Dictation intents
      (shipped in 1.9.4). Possible follow-up: a "Get Last Transcript" intent
      so Shortcuts pipelines can post-process dictated text.

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
