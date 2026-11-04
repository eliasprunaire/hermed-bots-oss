import XCTest
@testable import HermesAdapter

final class ProfileOpenRetryTests: XCTestCase {
    func testTheBackoffIsImmediateThen400Then1200Milliseconds() {
        XCTAssertEqual(ProfileOpenRetry.attemptCount, 3)
        XCTAssertEqual(ProfileOpenRetry.delay(beforeAttempt: 0), .zero)
        XCTAssertEqual(ProfileOpenRetry.delay(beforeAttempt: 1), .milliseconds(400))
        XCTAssertEqual(ProfileOpenRetry.delay(beforeAttempt: 2), .milliseconds(1_200))
    }

    func testRunStopsOnTheFirstSuccess() async throws {
        var attempts = 0
        let ok = try await ProfileOpenRetry.run {
            attempts += 1
            return attempts == 1
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(attempts, 1)
    }

    func testRunExhaustsThreeAttemptsBeforeFailing() async throws {
        var attempts = 0
        let ok = try await ProfileOpenRetry.run {
            attempts += 1
            return false
        }
        XCTAssertFalse(ok)
        XCTAssertEqual(attempts, 3)
    }
}

final class CompatibilityStatusTests: XCTestCase {
    func testACompatibleKnownVersionIsReadyWithoutABanner() throws {
        let map = CapabilityMap(version: "0.22.2", states: [:])
        XCTAssertFalse(map.showsBanner)
        XCTAssertEqual(CompatibilityStatus.of(map: map, checking: false, hasError: false), .ready)
        XCTAssertEqual(CompatibilityStatus.ready.footerLabel, "Prêt")
        XCTAssertEqual(CompatibilityStatus.thinkingLabel, "Le bot réfléchit…")
    }

    func testAnUntestedVersionGoesToTheFooterNotTheBanner() {
        let map = CapabilityMap(version: "0.22.5", states: [:])
        XCTAssertNotNil(map.versionNotice)
        XCTAssertFalse(map.showsBanner)
        XCTAssertEqual(CompatibilityStatus.of(map: map, checking: false, hasError: false), .untested)
        XCTAssertEqual(CompatibilityStatus.untested.footerLabel, "Compatibilité · voir Réglages")
    }

    func testCheckingHidesErrorsAndConnectingLabelIsUsed() {
        XCTAssertEqual(CompatibilityStatus.of(map: nil, checking: true, hasError: true), .connecting)
        XCTAssertEqual(CompatibilityStatus.connecting.footerLabel, "Connexion…")
        XCTAssertEqual(CompatibilityStatus.failed.footerLabel, "Clé refusée")
    }
}
