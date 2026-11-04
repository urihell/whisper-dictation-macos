import AppKit

/// Drives dictation from a modifier-only shortcut (Right ⌥ alone, ⌘⌥ together…)
/// using a CGEventTap. Every event passes through untouched — the modifiers
/// keep working in normal combos; `ModifierChordTracker` only fires when the
/// chord was pressed and released with nothing else in between.
///
/// A `.defaultTap` (not listen-only) because it needs the Accessibility trust
/// the app already holds; listen-only would require a separate Input
/// Monitoring grant.
final class ModifierShortcutMonitor {
    static let shared = ModifierShortcutMonitor()
    private init() {}

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tracker = ModifierChordTracker(target: [])

    func start(modifiers: Set<UInt16>) {
        stop()
        guard !modifiers.isEmpty else { return }
        tracker = ModifierChordTracker(target: modifiers)

        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                if let refcon {
                    Unmanaged<ModifierShortcutMonitor>.fromOpaque(refcon)
                        .takeUnretainedValue().process(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            Log.error("ModifierShortcutMonitor: failed to create event tap (Accessibility not granted?)")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.info("ModifierShortcutMonitor: started for \(ModifierKey.label(for: modifiers))")
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }

    private func process(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            Log.info("ModifierShortcutMonitor: tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input")")
        case .flagsChanged:
            let events = tracker.update(held: ModifierKey.held(flags: event.flags.rawValue))
            if !events.isEmpty {
                DispatchQueue.main.async { Self.handle(events) }
            }
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown:
            tracker.otherInput()
        default:
            break
        }
    }

    /// Push-to-talk follows the hold (chord down → start, up → stop). Toggle and
    /// double-tap act on a clean tap only, so ⌥-e or ⌘-click never fire.
    @MainActor
    private static func handle(_ events: [ModifierChordTracker.Event]) {
        let settings = AppSettings.shared
        let holdMode = !settings.doubleTapEnabled && settings.triggerMode == .pushToTalk
        let controller = DictationController.shared
        for event in events {
            switch (event, holdMode) {
            case (.chordDown, true):
                Log.info("Modifier shortcut down (state=\(controller.state))")
                controller.triggerDown()
            case (.chordUp, true):
                controller.triggerUp()
            case (.tap, false):
                Log.info("Modifier shortcut tap (state=\(controller.state))")
                controller.triggerDown()
                controller.triggerUp()
            default:
                break
            }
        }
    }
}
