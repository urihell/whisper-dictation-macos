import XCTest

final class VPIOFailurePolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let builtIn = "BuiltInMicrophoneDevice"
    private let usb = "AppleUSBAudioEngine:Shure:MV7+"

    func testUnknownDeviceIsNotSkipped() {
        XCTAssertFalse(VPIOFailurePolicy().shouldSkip(device: builtIn, now: t0))
    }

    func testFirstFailureCoolsDownThenRetries() {
        var p = VPIOFailurePolicy()
        XCTAssertEqual(p.recordFailure(device: usb, now: t0), .coolingDown(30))
        XCTAssertTrue(p.shouldSkip(device: usb, now: t0.addingTimeInterval(29)))
        XCTAssertFalse(p.shouldSkip(device: usb, now: t0.addingTimeInterval(31)))
    }

    func testSecondFailureDisablesUntilRelaunch() {
        var p = VPIOFailurePolicy()
        _ = p.recordFailure(device: usb, now: t0)
        XCTAssertEqual(p.recordFailure(device: usb, now: t0.addingTimeInterval(60)), .disabledUntilRelaunch)
        XCTAssertTrue(p.shouldSkip(device: usb, now: t0.addingTimeInterval(10_000)))
    }

    func testFreshPolicyRetriesEveryMic() {
        // A relaunch builds a fresh policy: nothing carries over.
        XCTAssertFalse(VPIOFailurePolicy().shouldSkip(device: usb, now: t0))
    }

    func testFailuresAreIsolatedPerDevice() {
        var p = VPIOFailurePolicy()
        _ = p.recordFailure(device: builtIn, now: t0)
        _ = p.recordFailure(device: builtIn, now: t0)
        XCTAssertFalse(p.shouldSkip(device: usb, now: t0))
    }
}
