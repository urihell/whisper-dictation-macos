import XCTest

final class SentenceChunkingTests: XCTestCase {
    func testHoldsBackNewestCompleteSentence() {
        let text = "First sentence. Second sentence. Trailing tail"
        guard let cut = SentenceChunking.holdBackCut(in: text) else {
            return XCTFail("expected a cut")
        }
        XCTAssertEqual(String(text[..<cut]), "First sentence.")
    }

    func testNilWithFewerThanTwoCompleteSentences() {
        XCTAssertNil(SentenceChunking.holdBackCut(in: "Just one sentence here."))
        XCTAssertNil(SentenceChunking.holdBackCut(in: "One done. Second still going"))
        XCTAssertNil(SentenceChunking.holdBackCut(in: "no enders at all"))
    }

    func testEnderRequiresFollowingWhitespace() {
        // "e.g.test" has periods with no following whitespace — not sentence ends.
        XCTAssertNil(SentenceChunking.holdBackCut(in: "see e.g.test for more. tail"))
        // Question/exclamation/ellipsis count as enders too.
        let text = "Really? Yes! And then… more to come"
        guard let cut = SentenceChunking.holdBackCut(in: text) else {
            return XCTFail("expected a cut")
        }
        // Three enders — cut after the second-newest ("Yes!").
        XCTAssertEqual(String(text[..<cut]), "Really? Yes!")
    }

    func testNormalizeCollapsesWhitespace() {
        XCTAssertEqual(
            SentenceChunking.normalize("  hello   world \n next  "),
            "hello world next"
        )
        XCTAssertEqual(SentenceChunking.normalize(""), "")
    }
}
