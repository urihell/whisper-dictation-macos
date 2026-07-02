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

    // MARK: - Localized punctuation

    func testSpanishPunctuation() {
        XCTAssertEqual(VoiceCommands.apply("hola coma mundo punto"), "Hola, mundo.")
        XCTAssertEqual(VoiceCommands.apply("uno punto y coma dos"), "Uno; dos")
        XCTAssertEqual(VoiceCommands.apply("nota dos puntos listo"), "Nota: listo")
    }

    func testFrenchPunctuation() {
        XCTAssertEqual(VoiceCommands.apply("bonjour virgule monde point"), "Bonjour, monde.")
        XCTAssertEqual(VoiceCommands.apply("quoi point d'interrogation"), "Quoi?")
        XCTAssertEqual(VoiceCommands.apply("un point-virgule deux"), "Un; deux")
    }

    func testGermanPunctuation() {
        XCTAssertEqual(VoiceCommands.apply("hallo komma welt punkt"), "Hallo, welt.")
        XCTAssertEqual(VoiceCommands.apply("warum fragezeichen"), "Warum?")
        XCTAssertEqual(VoiceCommands.apply("liste doppelpunkt eins"), "Liste: eins")
    }

    func testPortuguesePunctuation() {
        XCTAssertEqual(VoiceCommands.apply("olá vírgula mundo ponto"), "Olá, mundo.")
        XCTAssertEqual(VoiceCommands.apply("um ponto e vírgula dois"), "Um; dois")
    }

    func testHebrewPunctuation() {
        XCTAssertEqual(VoiceCommands.apply("שלום פסיק עולם נקודה"), "שלום, עולם.")
        XCTAssertEqual(VoiceCommands.apply("למה סימן שאלה"), "למה?")
        XCTAssertEqual(VoiceCommands.apply("רשימה נקודתיים אחת"), "רשימה: אחת")
    }

    func testChinesePunctuation() {
        XCTAssertEqual(VoiceCommands.apply("你好逗号世界句号"), "你好，世界。")
        XCTAssertEqual(VoiceCommands.apply("为什么问号"), "为什么？")
        XCTAssertEqual(VoiceCommands.apply("為什麼問號"), "為什麼？")
    }
}
