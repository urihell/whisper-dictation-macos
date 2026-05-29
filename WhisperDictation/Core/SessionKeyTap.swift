import AppKit

/// While a dictation session is active, intercepts Escape (cancel) and Return
/// (submit) globally and swallows them so they don't reach the focused app.
/// Requires Accessibility trust (same as the paste path).
final class SessionKeyTap {
    static let shared = SessionKeyTap()
    private init() {}

    /// Invoked (on the main queue) when the respective key is pressed.
    var onEscape: (() -> Void)?
    /// Returns true if Return should be intercepted/handled right now.
    var shouldHandleReturn: (() -> Bool)?
    var onReturn: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private static let escapeKey: Int64 = 53
    private static let returnKey: Int64 = 36
    private static let keypadEnterKey: Int64 = 76

    func start() {
        guard eventTap == nil else { return }
        let mask = (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<SessionKeyTap>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.process(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            Log.error("SessionKeyTap: failed to create event tap (Accessibility not granted?)")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }

    private func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        switch code {
        case Self.escapeKey:
            DispatchQueue.main.async { [weak self] in self?.onEscape?() }
            return nil // swallow
        case Self.returnKey, Self.keypadEnterKey:
            if shouldHandleReturn?() == true {
                DispatchQueue.main.async { [weak self] in self?.onReturn?() }
                return nil // swallow — we'll synthesize our own submit
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
