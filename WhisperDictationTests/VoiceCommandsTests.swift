import XCTest

final class VoiceCommandsTests: XCTestCase {
    // MARK: - Breaks

    func testNewLineAndNewParagraph() {
        XCTAssertEqual(VoiceCommands.apply("hello new line world"), "Hello\nWorld")
        XCTAssertEqual(VoiceCommands.apply("one new paragraph two"), "One\n\nTwo")
    }

    func testPluralAndHyphenatedForms() {
        XCTAssertEqual(VoiceCommands.apply("a new-line b"), "A\nB")
        XCTAssertEqual(VoiceCommands.apply("a newline b"), "A\nB")
    }

    // MARK: - Localized breaks

    func testSpanishBreaks() {
        XCTAssertEqual(VoiceCommands.apply("hola nueva línea mundo"), "Hola\nMundo")
        XCTAssertEqual(VoiceCommands.apply("uno nuevo párrafo dos"), "Uno\n\nDos")
    }

    func testFrenchBreaks() {
        XCTAssertEqual(VoiceCommands.apply("bonjour nouvelle ligne monde"), "Bonjour\nMonde")
        XCTAssertEqual(VoiceCommands.apply("un à la ligne deux"), "Un\nDeux")
    }

    func testGermanBreaks() {
        XCTAssertEqual(VoiceCommands.apply("hallo neue zeile welt"), "Hallo\nWelt")
        XCTAssertEqual(VoiceCommands.apply("eins neuer absatz zwei"), "Eins\n\nZwei")
    }

    func testPortugueseBreaks() {
        XCTAssertEqual(VoiceCommands.apply("olá nova linha mundo"), "Olá\nMundo")
    }

    func testHebrewBreaks() {
        XCTAssertEqual(VoiceCommands.apply("שלום שורה חדשה עולם"), "שלום\nעולם")
        XCTAssertEqual(VoiceCommands.apply("אחת פסקה חדשה שתיים"), "אחת\n\nשתיים")
    }

    func testChineseBreaks() {
        XCTAssertEqual(VoiceCommands.apply("你好换行世界"), "你好\n世界")
        XCTAssertEqual(VoiceCommands.apply("你好換行世界"), "你好\n世界")
        XCTAssertEqual(VoiceCommands.apply("一新段落二"), "一\n\n二")
    }

    // MARK: - Punctuation

    func testSpokenPunctuation() {
        XCTAssertEqual(VoiceCommands.apply("wait comma what question mark"), "Wait, what?")
        XCTAssertEqual(VoiceCommands.apply("done full stop next"), "Done. Next")
        XCTAssertEqual(VoiceCommands.apply("well hyphen known"), "Well-known")
    }

    /// Pinning test for the documented tradeoff: punctuation commands are
    /// literal, so "the Jurassic period" becomes "the Jurassic." by design.
    func testLiteralPeriodTradeoff() {
        XCTAssertEqual(VoiceCommands.apply("the Jurassic period"), "The Jurassic.")
    }

    func testPluralPunctuationWordsAreNotCommands() {
        XCTAssertEqual(VoiceCommands.apply("use commas often"), "Use commas often")
    }

    func testCapitalizesAfterInsertedSentenceMark() {
        XCTAssertEqual(VoiceCommands.apply("stop period next item"), "Stop. Next item")
    }
}
