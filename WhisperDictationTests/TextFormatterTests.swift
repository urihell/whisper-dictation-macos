import XCTest

final class TextFormatterTests: XCTestCase {
    func testCapitalizesStartAndAfterSentenceMarks() {
        XCTAssertEqual(
            TextFormatter.capitalizeSentences("hello world. this is fine! is it? yes"),
            "Hello world. This is fine! Is it? Yes"
        )
    }

    func testCapitalizesAfterLineBreaks() {
        XCTAssertEqual(
            TextFormatter.capitalizeSentences("first line\nsecond line\n\nthird"),
            "First line\nSecond line\n\nThird"
        )
    }

    func testLeavesUppercaseAndAccentedStartsAlone() {
        XCTAssertEqual(TextFormatter.capitalizeSentences("Already fine. Étude begins"),
                       "Already fine. Étude begins")
    }

    func testFixStandaloneI() {
        XCTAssertEqual(
            TextFormatter.fixStandaloneI("i think i'm right, aren't i"),
            "I think I'm right, aren't I"
        )
    }

    func testFixStandaloneIDoesNotTouchWordsContainingI() {
        XCTAssertEqual(TextFormatter.fixStandaloneI("i went in with insight"),
                       "I went in with insight")
    }

    func testAutoCapitalizeEnglishFlag() {
        XCTAssertEqual(TextFormatter.autoCapitalize("say i see", english: true), "Say I see")
        XCTAssertEqual(TextFormatter.autoCapitalize("say i see", english: false), "Say i see")
    }

    func testEmptyString() {
        XCTAssertEqual(TextFormatter.capitalizeSentences(""), "")
    }
}
