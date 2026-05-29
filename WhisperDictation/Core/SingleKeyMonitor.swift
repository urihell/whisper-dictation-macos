import AppKit

/// Intercepts a single configured key system-wide using a CGEventTap and uses
/// it to drive dictation. The trigger key is *swallowed* (not delivered to the
/// focused app) so it doesn't type its character. Requires Accessibility trust.
final class SingleKeyMonitor {
    static let shared = SingleKeyMonitor()
    private init() {}

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var keyCode: CGKeyCode = 0
    private var isKeyDown = false

    var isRunning: Bool { eventTap != nil }

    func start(keyCode: CGKeyCode) {
        stop()
        self.keyCode = keyCode
        self.isKeyDown = false

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<SingleKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.process(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            Log.error("SingleKeyMonitor: failed to create event tap (Accessibility not granted?)")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.info("SingleKeyMonitor: started for keyCode \(keyCode)")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isKeyDown = false
    }

    private func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that takes too long or on user input; re-enable.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard code == keyCode else {
            return Unmanaged.passUnretained(event) // not our key — pass through
        }

        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        switch type {
        case .keyDown:
            if !isRepeat, !isKeyDown {
                isKeyDown = true
                DispatchQueue.main.async { DictationController.shared.triggerDown() }
            }
            return nil // swallow so the key doesn't type
        case .keyUp:
            isKeyDown = false
            DispatchQueue.main.async { DictationController.shared.triggerUp() }
            return nil // swallow
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
