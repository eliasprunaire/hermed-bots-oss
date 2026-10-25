import XCTest
import UpdateCheck

final class FakeUpdateDriver: UpdateDriver {
    var canStartCheck = true
    var starts = 0
    var beginSession = true

    func startCheck() -> Bool {
        starts += 1
        return beginSession
    }
}

final class UpdateCheckTests: XCTestCase {
    func testAReadyActionStartsOneDriverCheck() {
        let driver = FakeUpdateDriver()
        let updates = UpdateCheck(driver: driver)
        updates.checkForUpdates()
        XCTAssertEqual(driver.starts, 1)
        XCTAssertTrue(updates.isChecking)
        XCTAssertFalse(updates.canCheck)
    }

    func testASecondActionDuringACheckStartsNone() {
        let driver = FakeUpdateDriver()
        let updates = UpdateCheck(driver: driver)
        updates.checkForUpdates()
        updates.checkForUpdates()
        XCTAssertEqual(driver.starts, 1)
        XCTAssertTrue(updates.isChecking)
    }

    func testCanCheckIsFalseDuringTheSessionAndTrueAfterItEnds() {
        let driver = FakeUpdateDriver()
        let updates = UpdateCheck(driver: driver)
        XCTAssertTrue(updates.canCheck)
        updates.checkForUpdates()
        XCTAssertFalse(updates.canCheck)
        updates.noteSessionEnded()
        XCTAssertFalse(updates.isChecking)
        XCTAssertTrue(updates.canCheck)
        updates.checkForUpdates()
        XCTAssertEqual(driver.starts, 2)
    }

    func testADriverThatIsNotReadyStartsNothing() {
        let driver = FakeUpdateDriver()
        driver.canStartCheck = false
        let updates = UpdateCheck(driver: driver)
        XCTAssertFalse(updates.canCheck)
        updates.checkForUpdates()
        XCTAssertEqual(driver.starts, 0)
        XCTAssertFalse(updates.isChecking)
    }

    func testADriverThatDoesNotBeginASessionClearsChecking() {
        let driver = FakeUpdateDriver()
        driver.beginSession = false
        let updates = UpdateCheck(driver: driver)
        updates.checkForUpdates()
        XCTAssertEqual(driver.starts, 1)
        XCTAssertFalse(updates.isChecking)
        XCTAssertTrue(updates.canCheck)
    }

    func testRepeatedChecksWhileAlreadyCheckingStayCheap() {
        let driver = FakeUpdateDriver()
        let updates = UpdateCheck(driver: driver)
        updates.checkForUpdates()
        for _ in 0..<10_000 {
            updates.checkForUpdates()
        }
        XCTAssertEqual(driver.starts, 1)
    }
}
