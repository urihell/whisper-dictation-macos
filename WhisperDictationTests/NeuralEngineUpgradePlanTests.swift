import XCTest

final class NeuralEngineUpgradePlanTests: XCTestCase {
    typealias Plan = NeuralEngineUpgradePlan

    func testSwitchingToNeuralEngineKeepsGPUServing() {
        XCTAssertEqual(Plan.onBackendChange(wantsNeuralEngine: true, runningOnNeuralEngine: false), .startUpgrade)
    }

    func testSwitchingBackToGPUWhileUpgradePendingJustCancels() {
        XCTAssertEqual(Plan.onBackendChange(wantsNeuralEngine: false, runningOnNeuralEngine: false), .cancelUpgrade)
    }

    func testLeavingNeuralEngineReloadsOnGPU() {
        XCTAssertEqual(Plan.onBackendChange(wantsNeuralEngine: false, runningOnNeuralEngine: true), .reload)
    }

    func testAlreadyOnNeuralEngineIsNoOp() {
        XCTAssertEqual(Plan.onBackendChange(wantsNeuralEngine: true, runningOnNeuralEngine: true), .none)
    }

    func testAdoptOnlyBetweenSessions() {
        XCTAssertTrue(Plan.canAdopt(upgradeModel: "m", activeModel: "m", sessionRunning: false))
        XCTAssertFalse(Plan.canAdopt(upgradeModel: "m", activeModel: "m", sessionRunning: true))
    }

    func testNeverAdoptForAModelNoLongerActive() {
        XCTAssertFalse(Plan.canAdopt(upgradeModel: "old", activeModel: "new", sessionRunning: false))
        XCTAssertFalse(Plan.canAdopt(upgradeModel: "m", activeModel: nil, sessionRunning: false))
    }
}
