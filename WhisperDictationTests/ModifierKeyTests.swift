import XCTest

final class ModifierKeyTests: XCTestCase {
    private let rightOpt: UInt16 = 61
    private let leftOpt: UInt16 = 58
    private let leftCmd: UInt16 = 55

    // MARK: ModifierKey

    func testRecognizesModifiersButNotCapsLockOrLetters() {
        XCTAssertTrue(ModifierKey.isModifier(61))
        XCTAssertTrue(ModifierKey.isModifier(63))   // fn
        XCTAssertFalse(ModifierKey.isModifier(57))  // caps lock — toggles, unusable
        XCTAssertFalse(ModifierKey.isModifier(0))   // "A"
    }

    /// Left and right ⌥ share the generic ⌥ flag; only the device bit tells
    /// them apart.
    func testHeldDistinguishesSides() {
        XCTAssertEqual(ModifierKey.held(flags: 0x0008_0000 | 0x40), [rightOpt])
        XCTAssertEqual(ModifierKey.held(flags: 0x0008_0000 | 0x20), [leftOpt])
        XCTAssertEqual(ModifierKey.held(flags: 0x0018_0000 | 0x20 | 0x08), [leftOpt, leftCmd])
        XCTAssertEqual(ModifierKey.held(flags: 0x100), [])   // non-coalesced bit only
    }

    func testLabels() {
        XCTAssertEqual(ModifierKey.label(for: [rightOpt]), "Right ⌥")
        XCTAssertEqual(ModifierKey.label(for: [leftCmd, leftOpt]), "Left ⌥ + Left ⌘")
        XCTAssertEqual(ModifierKey.label(for: []), "")
    }

    // MARK: ModifierChordTracker — single modifier

    func testLoneTap() {
        var t = ModifierChordTracker(target: [rightOpt])
        XCTAssertEqual(t.update(held: [rightOpt]), [.chordDown])
        XCTAssertEqual(t.update(held: []), [.chordUp, .tap])
    }

    func testComboWithKeyIsNotATap() {
        var t = ModifierChordTracker(target: [rightOpt])
        _ = t.update(held: [rightOpt])
        t.otherInput()                                  // ⌥-e
        XCTAssertEqual(t.update(held: []), [.chordUp])  // PTT still stops; no tap
    }

    func testOtherSideDoesNotFire() {
        var t = ModifierChordTracker(target: [rightOpt])
        XCTAssertEqual(t.update(held: [leftOpt]), [])
        XCTAssertEqual(t.update(held: []), [])
    }

    func testInputBeforeGestureDoesNotSpoilIt() {
        var t = ModifierChordTracker(target: [rightOpt])
        t.otherInput()                                  // typing, nothing held
        _ = t.update(held: [rightOpt])
        XCTAssertEqual(t.update(held: []), [.chordUp, .tap])
    }

    // MARK: ModifierChordTracker — chords

    func testChordInEitherPressOrder() {
        var t = ModifierChordTracker(target: [leftCmd, leftOpt])
        XCTAssertEqual(t.update(held: [leftOpt]), [])
        XCTAssertEqual(t.update(held: [leftOpt, leftCmd]), [.chordDown])
        XCTAssertEqual(t.update(held: [leftCmd]), [.chordUp])   // released unevenly
        XCTAssertEqual(t.update(held: []), [.tap])
    }

    func testSubsetOfChordIsNotATap() {
        var t = ModifierChordTracker(target: [leftCmd, leftOpt])
        _ = t.update(held: [leftOpt])
        XCTAssertEqual(t.update(held: []), [])
    }

    /// ⌥⌘ + ⇧ is a different chord — a superset must not fire.
    func testExtraModifierSpoilsChord() {
        var t = ModifierChordTracker(target: [leftCmd, leftOpt])
        _ = t.update(held: [leftCmd, leftOpt])
        XCTAssertEqual(t.update(held: [leftCmd, leftOpt, 56]), [.chordUp])
        XCTAssertEqual(t.update(held: []), [])
    }

    func testStateResetsBetweenGestures() {
        var t = ModifierChordTracker(target: [rightOpt])
        _ = t.update(held: [rightOpt]); t.otherInput(); _ = t.update(held: [])
        XCTAssertEqual(t.update(held: [rightOpt]), [.chordDown])
        XCTAssertEqual(t.update(held: []), [.chordUp, .tap])
    }

    func testEmptyTargetNeverFires() {
        var t = ModifierChordTracker(target: [])
        XCTAssertEqual(t.update(held: [rightOpt]), [])
        XCTAssertEqual(t.update(held: []), [])
    }
}
