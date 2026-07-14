import XCTest

final class SettingsExportTests: XCTestCase {
    func testRoundTrip() throws {
        var export = SettingsExport()
        export.triggerMode = "pushToTalk"
        export.language = "he"
        export.vocabularyTerms = ["WhisperKit", "Dabby"]
        export.replacements = ["cat": "Katherine"]
        export.appProfiles = [
            AppProfile(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp",
                       pressReturn: true, useClipboard: nil, language: "he", inputDeviceUID: nil)
        ]
        let data = try JSONEncoder().encode(export)
        let decoded = try JSONDecoder().decode(SettingsExport.self, from: data)
        XCTAssertEqual(decoded, export)
    }

    /// A minimal/partial file (older app version, hand-edited) must decode —
    /// missing fields stay nil so the importer leaves those settings alone.
    func testPartialFileDecodes() throws {
        let json = Data("""
        {"formatVersion": 1, "language": "en"}
        """.utf8)
        let decoded = try JSONDecoder().decode(SettingsExport.self, from: json)
        XCTAssertEqual(decoded.language, "en")
        XCTAssertNil(decoded.vocabularyTerms)
        XCTAssertNil(decoded.appProfiles)
    }

    /// Unknown fields from a FUTURE version must not break import.
    func testUnknownFieldsIgnored() throws {
        let json = Data("""
        {"formatVersion": 2, "language": "fr", "someFutureSetting": true}
        """.utf8)
        let decoded = try JSONDecoder().decode(SettingsExport.self, from: json)
        XCTAssertEqual(decoded.language, "fr")
    }

    func testGarbageFailsToDecode() {
        XCTAssertThrowsError(try JSONDecoder().decode(SettingsExport.self, from: Data("not json".utf8)))
    }
}
