import XCTest

// compilé dans le paquet de tests lui-même, sans l'app comme hôte
final class WorkingRingTests: XCTestCase {
    func testTheRingMakesOneTurnPerPeriod() {
        let period = WorkingRing.period
        XCTAssertEqual(WorkingRing.angle(at: 0, moving: true), 0, accuracy: 0.001)
        XCTAssertEqual(WorkingRing.angle(at: period / 2, moving: true), 180, accuracy: 0.001)
        XCTAssertEqual(WorkingRing.angle(at: period * 40 + period / 4, moving: true), 90, accuracy: 0.001)
    }

    func testTheAngleStaysInOneTurnForAnyTime() {
        for time in [0, 0.001, 1.399, 1.4, 1.401, 86_400.123, 800_000_000.5] {
            let angle = WorkingRing.angle(at: time, moving: true)
            XCTAssert((0..<360).contains(angle), "\(time) donne \(angle)")
        }
    }

    // « Réduire les animations » activé pendant un tour : l'angle dépend du réglage à chaque image, pas d'un état pris à l'apparition de l'anneau
    func testTheRingStopsAtOnceWhenMotionIsCutAndTurnsAgainWhenItComes() {
        let time = 123.45
        let turning = WorkingRing.angle(at: time, moving: true)
        XCTAssertNotEqual(turning, 0, "l'instant de l'essai doit tomber hors d'un tour entier")
        XCTAssertEqual(WorkingRing.angle(at: time, moving: false), 0)
        XCTAssertEqual(WorkingRing.angle(at: time, moving: true), turning)
    }
}
