import XCTest

final class HallucinationFilterTests: XCTestCase {
    // MARK: - Phrase matches (whole-text, after normalization)

    func testEnglishThankYouVariants() {
        XCTAssertTrue(HallucinationFilter.isLikelySilenceHallucination("Thank you."))
        XCTAssertTrue(HallucinationFilter.isLikelySilenceHallucination("thank you"))
        XCTAssertTrue(HallucinationFilter.isLikelySilenceHallucination("Thanks for watching!"))
        XCTAssertTrue(HallucinationFilter.isLikelySilenceHallucination("Thank you so much for watching"))
    }

    func testNormalizationStripsEdgePunctuationAndCase() {
        XCTAssertTrue(HallucinationFilter.isLikelySilenceHallucination("¡Gracias!"))
        XCTAssertTrue(HallucinationFilter.isLikelySilenceHallucination("  MERCI.  "))
        XCTAssertTrue(HallucinationFilter.isLikelySilenceHallucination("谢谢观看。"))
    }

    func testMultilingualPhrases() {
        XCTAssertTrue(HallucinationFilter.isLikelySilenceHallucination("תודה רבה"))
        XCTAssertTrue(HallucinationFilter.isLikelySilenceHallucination("ご視聴ありがとうございました"))
        XCTAssertTrue(HallucinationFilter.isLikelySilenceHallucination("Vielen Dank fürs Zuschauen"))
    }

    // MARK: - Marker matches (substring)

    func testCaptionCreditMarkers() {
        XCTAssertTrue(HallucinationFilter.isLikelySilenceHallucination("Subtitles by the Amara.org community"))
        XCTAssertTrue(HallucinationFilter.isLikelySilenceHallucination("Sous-titrage ST' 501"))
    }

    // MARK: - Real dictation must pass through

    func testRealSpeechIsNotFlagged() {
        XCTAssertFalse(HallucinationFilter.isLikelySilenceHallucination("thank you for the report"))
        XCTAssertFalse(HallucinationFilter.isLikelySilenceHallucination("The quarterly numbers look good"))
        XCTAssertFalse(HallucinationFilter.isLikelySilenceHallucination("please send my thanks to the team"))
    }

    func testEmptyAndWhitespaceAreNotFlagged() {
        XCTAssertFalse(HallucinationFilter.isLikelySilenceHallucination(""))
        XCTAssertFalse(HallucinationFilter.isLikelySilenceHallucination("   "))
    }
}
