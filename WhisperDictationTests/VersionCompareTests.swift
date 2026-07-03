import XCTest

final class VersionCompareTests: XCTestCase {
    func testBasicOrdering() {
        XCTAssertTrue(VersionCompare.isNewer("1.9.5", than: "1.9.4"))
        XCTAssertFalse(VersionCompare.isNewer("1.9.4", than: "1.9.4"))
        XCTAssertFalse(VersionCompare.isNewer("1.9.3", than: "1.9.4"))
    }

    /// The reason string comparison isn't enough: "1.10.0" > "1.9.4".
    func testMultiDigitComponents() {
        XCTAssertTrue(VersionCompare.isNewer("1.10.0", than: "1.9.4"))
        XCTAssertTrue(VersionCompare.isNewer("2.0.0", than: "1.99.99"))
    }

    func testMissingComponentsCountAsZero() {
        XCTAssertFalse(VersionCompare.isNewer("1.9", than: "1.9.0"))
        XCTAssertTrue(VersionCompare.isNewer("1.9.1", than: "1.9"))
    }

    func testLeadingVPrefixTolerated() {
        XCTAssertTrue(VersionCompare.isNewer("v1.9.5", than: "1.9.4"))
        XCTAssertFalse(VersionCompare.isNewer("v1.9.4", than: "v1.9.4"))
    }

    func testNonNumericSuffixIgnored() {
        // "1.9.5-beta" compares as 1.9.5 (numeric prefix per component).
        XCTAssertTrue(VersionCompare.isNewer("1.9.5-beta", than: "1.9.4"))
    }
}
