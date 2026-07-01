import XCTest

final class ReplacementEngineTests: XCTestCase {
    func testWholeWordOnly() {
        XCTAssertEqual(
            ReplacementEngine.apply("the cat in category", rules: ["cat": "dog"]),
            "the dog in category"
        )
    }

    func testCaseInsensitiveMatching() {
        XCTAssertEqual(
            ReplacementEngine.apply("Cat and CAT", rules: ["cat": "dog"]),
            "dog and dog"
        )
    }

    func testMultiWordKey() {
        XCTAssertEqual(
            ReplacementEngine.apply("meet me in new york tomorrow", rules: ["new york": "NYC"]),
            "meet me in NYC tomorrow"
        )
    }

    /// Overlapping rules must apply longest-key-first, deterministically —
    /// with dictionary-order iteration this flapped run to run.
    func testLongestKeyWins() {
        let rules = ["new york": "NY", "new york city": "NYC"]
        XCTAssertEqual(
            ReplacementEngine.apply("i love new york city", rules: rules),
            "i love NYC"
        )
        XCTAssertEqual(
            ReplacementEngine.apply("i love new york", rules: rules),
            "i love NY"
        )
    }

    func testKeysWithRegexSpecialCharacters() {
        XCTAssertEqual(
            ReplacementEngine.apply("i use c++ daily", rules: ["c++": "Swift"]),
            "i use Swift daily"
        )
    }

    func testReplacementValueWithDollarSignIsLiteral() {
        XCTAssertEqual(
            ReplacementEngine.apply("the total cost", rules: ["cost": "$100"]),
            "the total $100"
        )
    }

    func testBoundaryAtStringEdges() {
        XCTAssertEqual(ReplacementEngine.apply("cat", rules: ["cat": "dog"]), "dog")
    }

    func testEmptyRulesAndEmptyKeys() {
        XCTAssertEqual(ReplacementEngine.apply("unchanged", rules: [:]), "unchanged")
        XCTAssertEqual(ReplacementEngine.apply("unchanged", rules: ["": "x"]), "unchanged")
    }
}
