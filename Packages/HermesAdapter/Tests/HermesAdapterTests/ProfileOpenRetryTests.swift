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

    func testADefinitiveErrorWinsOverAConnectingCheck() {
        XCTAssertEqual(CompatibilityStatus.of(map: nil, checking: true, hasError: true), .failed)
        XCTAssertEqual(CompatibilityStatus.of(map: nil, checking: true, hasError: false), .connecting)
        XCTAssertEqual(CompatibilityStatus.connecting.footerLabel, "Connexion…")
        XCTAssertEqual(CompatibilityStatus.failed.footerLabel, "Clé refusée")
        XCTAssertFalse(
            CompatibilityStatus.failed.footerLabel.contains("refusée"),
            "Clé API introuvable sur l'hôte pour le profil hv-bot-b."
        )
        XCTAssertEqual(CompatibilityStatus.footerLabel(status: .failed, tunnelFailed: false), "Clé refusée")
        XCTAssertEqual(CompatibilityStatus.footerLabel(status: .failed, tunnelFailed: true), "Tunnel en échec")
        XCTAssertEqual(CompatibilityStatus.footerLabel(status: .ready, tunnelFailed: true), "Prêt")
        XCTAssertEqual(CompatibilityStatus.composerUnavailable, "Indisponible : la clé API est refusée")
        XCTAssertEqual(CompatibilityStatus.composerMissingKey, "Indisponible : la clé API est introuvable")
        XCTAssertNotEqual(CompatibilityStatus.composerUnavailable, CompatibilityStatus.composerMissingKey)
        XCTAssertEqual(CompatibilityStatus.waitingChatBody, "Réessayez la connexion pour ouvrir le fil.")
        XCTAssertFalse(CompatibilityStatus.waitingChatBody.contains("backoff"))
        XCTAssertFalse(CompatibilityStatus.waitingChatBody.contains("relecture"))
        XCTAssertTrue(CompatibilityStatus.compactedEstimateNotice.contains("Estimation"))
        XCTAssertNotEqual(CompatibilityStatus.compactedNotice, CompatibilityStatus.compactedEstimateNotice)
    }
}
