import CoreGraphics

/// Modifier keys (⌥, ⌘, ⇧, ⌃, fn) used ALONE as the dictation shortcut — e.g.
/// Right ⌥ by itself, or ⌘⌥ pressed together with no other key.
///
/// Why this exists: while another app holds Secure Event Input (a focused
/// password field — browsers sometimes leave it on), macOS withholds ⌥-only
/// key-combo hotkeys. A modifier-only shortcut is watched via `flagsChanged`
/// instead of a Carbon hotkey, so it can't collide with typing (⌥-e, ⌘-C still
/// work: a chord only fires when nothing else was pressed while it was held).
enum ModifierKey {
    /// Device-dependent flag bits (IOKit `NX_DEVICE*KEYMASK`) per key code, so
    /// left and right variants are told apart. fn has no sided bit.
    private static let deviceMasks: [UInt16: UInt64] = [
        59: 0x0000_0001, // left ⌃
        56: 0x0000_0002, // left ⇧
        60: 0x0000_0004, // right ⇧
        55: 0x0000_0008, // left ⌘
        54: 0x0000_0010, // right ⌘
        58: 0x0000_0020, // left ⌥
        61: 0x0000_0040, // right ⌥
        62: 0x0000_2000, // right ⌃
        63: 0x0080_0000, // fn (CGEventFlags.maskSecondaryFn)
    ]

    /// Display order follows the macOS convention: ⌃ ⌥ ⇧ ⌘, then fn.
    private static let symbols: [(code: UInt16, side: String, symbol: String)] = [
        (59, "Left", "⌃"), (62, "Right", "⌃"),
        (58, "Left", "⌥"), (61, "Right", "⌥"),
        (56, "Left", "⇧"), (60, "Right", "⇧"),
        (55, "Left", "⌘"), (54, "Right", "⌘"),
        (63, "", "fn"),
    ]

    static func isModifier(_ keyCode: UInt16) -> Bool {
        deviceMasks[keyCode] != nil
    }

    /// The modifier keys held according to an event's raw flags.
    static func held(flags: UInt64) -> Set<UInt16> {
        Set(deviceMasks.compactMap { flags & $0.value != 0 ? $0.key : nil })
    }

    /// "Right ⌥", "Left ⌘ + Left ⌥", "fn". Empty for an empty set.
    static func label(for codes: Set<UInt16>) -> String {
        symbols.filter { codes.contains($0.code) }
            .map { $0.side.isEmpty ? $0.symbol : "\($0.side) \($0.symbol)" }
            .joined(separator: " + ")
    }
}

/// Recognizes a modifier-only chord from successive modifier states. Pure (no
/// event-tap or settings access) so it's unit-tested.
///
/// Fed the full set of held modifiers on every `flagsChanged` — derived from the
/// event's flags rather than tracked press-by-press, so a missed event can't
/// leave it stuck. A "gesture" runs from the first modifier going down to all
/// modifiers being up again.
struct ModifierChordTracker {
    enum Event: Equatable {
        /// Exactly the target chord is now held (push-to-talk start).
        case chordDown
        /// The chord is no longer held after a `.chordDown` (push-to-talk stop).
        case chordUp
        /// The gesture ended having used exactly the target chord and nothing
        /// else — no extra modifier, no other key or click (toggle / double-tap).
        case tap
    }

    let target: Set<UInt16>
    private var held: Set<UInt16> = []
    private var seen: Set<UInt16> = []
    private var interrupted = false
    private var chordActive = false

    init(target: Set<UInt16>) {
        self.target = target
    }

    /// A non-modifier key or click. Spoils the current gesture (⌥-e, ⌘-click).
    mutating func otherInput() {
        if !held.isEmpty { interrupted = true }
    }

    mutating func update(held now: Set<UInt16>) -> [Event] {
        guard !target.isEmpty else { return [] }
        var events: [Event] = []
        if held.isEmpty, !now.isEmpty {     // a new gesture starts
            seen = []
            interrupted = false
        }
        held = now
        seen.formUnion(now)

        if chordActive, held != target {
            chordActive = false
            events.append(.chordUp)
        } else if !chordActive, !interrupted, held == target, seen == target {
            chordActive = true
            events.append(.chordDown)
        }

        if held.isEmpty, !seen.isEmpty {    // gesture over
            if !interrupted, seen == target { events.append(.tap) }
            seen = []
            interrupted = false
        }
        return events
    }
}
