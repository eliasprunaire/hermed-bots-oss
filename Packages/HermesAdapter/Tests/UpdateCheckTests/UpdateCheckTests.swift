import XCTest
import UpdateCheck

final class FakeUpdateDriver: UpdateDriver {
    var canStartCheck = true
    var starts = 0
    var installs = 0
    var beginSession = true

    func startCheck() -> Bool {
        starts += 1
        return beginSession
    }

    func startInstall() -> Bool {
        installs += 1
        return true
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

    func testPersistedAutomaticChecksAreTurnedOff() {
        let stored = UpdatePolicy(automaticallyChecks: true, automaticallyDownloads: true)
        XCTAssertEqual(UpdatePolicy.imposed(on: stored), .onDemand)
        XCTAssertEqual(
            UpdatePolicy.imposed(on: UpdatePolicy(automaticallyChecks: false, automaticallyDownloads: true)),
            .onDemand
        )
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

    func testIdleAndACheckWithNoUpdateAreUpToDate() {
        let driver = FakeUpdateDriver()
        let updates = UpdateCheck(driver: driver)
        XCTAssertEqual(updates.state, .idle)
        XCTAssertEqual(updates.state.statusText, "")
        XCTAssertFalse(updates.state.showsStatus)
        XCTAssertFalse(updates.state.showsInstall)
        updates.checkForUpdates()
        XCTAssertEqual(updates.state, .checking)
        updates.noteUpToDate()
        XCTAssertEqual(updates.state, .checking)
        updates.noteSessionEnded()
        XCTAssertEqual(updates.state, .upToDate)
        XCTAssertEqual(updates.state.statusText, UpdateCheckCopy.upToDate)
        XCTAssertTrue(updates.state.showsStatus)
        XCTAssertFalse(updates.state.showsInstall)
        XCTAssertTrue(updates.canCheck)
    }

    func testTheUpToDateCopyAppearsOnlyAfterASuccessfulCheck() {
        let driver = FakeUpdateDriver()
        let updates = UpdateCheck(driver: driver)
        XCTAssertNotEqual(updates.state, .upToDate)
        XCTAssertNotEqual(updates.state.statusText, UpdateCheckCopy.upToDate)
        XCTAssertFalse(updates.state.showsStatus)
        updates.checkForUpdates()
        XCTAssertEqual(updates.state, .checking)
        XCTAssertNotEqual(updates.state.statusText, UpdateCheckCopy.upToDate)
        updates.noteFailed()
        updates.noteSessionEnded()
        XCTAssertEqual(updates.state, .error)
        XCTAssertNotEqual(updates.state.statusText, UpdateCheckCopy.upToDate)
        updates.checkForUpdates()
        updates.noteUpToDate()
        XCTAssertNotEqual(updates.state.statusText, UpdateCheckCopy.upToDate)
        updates.noteSessionEnded()
        XCTAssertEqual(updates.state, .upToDate)
        XCTAssertEqual(updates.state.statusText, "Hermed Bots est à jour.")
        XCTAssertTrue(updates.state.showsStatus)
        XCTAssertFalse(updates.state.showsInstall)
    }

    func testARunningCheckShowsTheCheckingStatusAndDisablesAnotherCheck() {
        let driver = FakeUpdateDriver()
        let updates = UpdateCheck(driver: driver)
        updates.checkForUpdates()
        XCTAssertEqual(updates.state, .checking)
        XCTAssertEqual(updates.state.statusText, "Recherche de mises à jour…")
        XCTAssertEqual(updates.state.statusText, UpdateCheckCopy.checking)
        XCTAssertFalse(updates.state.showsInstall)
        XCTAssertFalse(updates.canCheck)
        updates.installUpdate()
        XCTAssertEqual(driver.installs, 0)
    }

    func testAFoundUpdateShowsTheVersionAndStartsTheDriverInstall() {
        let driver = FakeUpdateDriver()
        let updates = UpdateCheck(driver: driver)
        updates.checkForUpdates()
        updates.noteAvailable(version: "0.1.9")
        XCTAssertEqual(updates.state, .available(version: "0.1.9"))
        updates.noteSessionEnded()
        XCTAssertEqual(updates.state, .available(version: "0.1.9"))
        XCTAssertEqual(updates.state.statusText, "Mise à jour disponible : 0.1.9")
        XCTAssertTrue(updates.state.showsInstall)
        XCTAssertTrue(updates.canCheck)
        updates.installUpdate()
        XCTAssertEqual(driver.installs, 1)
        XCTAssertEqual(driver.starts, 1)
        XCTAssertEqual(updates.state, .available(version: "0.1.9"))
    }

    func testAFoundUpdateShowsInstallBeforeTheSessionEnds() {
        let driver = FakeUpdateDriver()
        let updates = UpdateCheck(driver: driver)
        updates.checkForUpdates()
        updates.noteAvailable(version: "0.1.9")
        XCTAssertEqual(updates.state, .available(version: "0.1.9"))
        XCTAssertTrue(updates.state.showsInstall)
        XCTAssertFalse(updates.canCheck)
        updates.checkForUpdates()
        XCTAssertEqual(driver.starts, 1)
        updates.noteSessionEnded()
        XCTAssertEqual(updates.state, .available(version: "0.1.9"))
        XCTAssertTrue(updates.state.showsInstall)
        XCTAssertTrue(updates.canCheck)
    }

    func testAFailedCheckShowsTheErrorAndHidesInstall() {
        let driver = FakeUpdateDriver()
        let updates = UpdateCheck(driver: driver)
        updates.checkForUpdates()
        updates.noteFailed()
        updates.noteSessionEnded()
        XCTAssertEqual(updates.state, .error)
        XCTAssertEqual(
            updates.state.statusText,
            "La recherche a échoué. Vérifie la connexion, puis réessaie."
        )
        XCTAssertEqual(updates.state.statusText, UpdateCheckCopy.failed)
        XCTAssertFalse(updates.state.showsInstall)
        XCTAssertTrue(updates.canCheck)
        updates.installUpdate()
        XCTAssertEqual(driver.installs, 0)
    }

    func testACanceledInstallKeepsTheAvailableUpdate() {
        let driver = FakeUpdateDriver()
        let updates = UpdateCheck(driver: driver)
        updates.checkForUpdates()
        updates.noteAvailable(version: "0.1.9")
        updates.noteSessionEnded()
        updates.checkForUpdates()
        updates.noteAvailable(version: "0.1.9")
        updates.noteSessionEnded()
        XCTAssertEqual(updates.state, .available(version: "0.1.9"))
        XCTAssertEqual(driver.starts, 2)
    }
}
