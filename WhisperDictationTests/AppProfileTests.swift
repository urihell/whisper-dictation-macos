import XCTest

final class AppProfileTests: XCTestCase {
    private let profiles = [
        AppProfile(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", pressReturn: true, useClipboard: nil, language: nil, inputDeviceUID: nil),
        AppProfile(bundleID: "com.microsoft.VSCode", name: "VS Code", pressReturn: nil, useClipboard: true, language: "en", inputDeviceUID: ""),
        AppProfile(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", pressReturn: nil, useClipboard: nil, language: "he", inputDeviceUID: "BuiltInMicrophoneDevice"),
    ]

    func testLookupByBundleID() {
        let hit = AppProfile.profile(for: "com.tinyspeck.slackmacgap", in: profiles)
        XCTAssertEqual(hit?.name, "Slack")
        XCTAssertEqual(hit?.pressReturn, true)
        XCTAssertNil(hit?.useClipboard)
    }

    func testLookupIsCaseInsensitive() {
        XCTAssertEqual(AppProfile.profile(for: "COM.MICROSOFT.VSCODE", in: profiles)?.name, "VS Code")
    }

    func testNoMatchAndNilBundleID() {
        XCTAssertNil(AppProfile.profile(for: "com.apple.Safari", in: profiles))
        XCTAssertNil(AppProfile.profile(for: nil, in: profiles))
    }

    /// The tri-state fields must round-trip through JSON, nils included —
    /// that's how they persist in UserDefaults.
    func testCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(profiles)
        let decoded = try JSONDecoder().decode([AppProfile].self, from: data)
        XCTAssertEqual(decoded, profiles)
        XCTAssertNil(decoded[0].useClipboard)
        XCTAssertEqual(decoded[1].useClipboard, true)
        XCTAssertEqual(decoded[2].language, "he")
        XCTAssertEqual(decoded[1].inputDeviceUID, "")   // explicit "system default"
        XCTAssertEqual(decoded[2].inputDeviceUID, "BuiltInMicrophoneDevice")
        XCTAssertNil(decoded[0].inputDeviceUID)         // follow global
    }

    /// Profiles saved before the language field existed must decode with
    /// language == nil (follow global), not fail.
    func testDecodingLegacyProfileWithoutLanguage() throws {
        let legacy = Data("""
        [{"bundleID":"com.apple.Safari","name":"Safari","pressReturn":true}]
        """.utf8)
        let decoded = try JSONDecoder().decode([AppProfile].self, from: legacy)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].pressReturn, true)
        XCTAssertNil(decoded[0].language)
        XCTAssertNil(decoded[0].useClipboard)
    }
}
