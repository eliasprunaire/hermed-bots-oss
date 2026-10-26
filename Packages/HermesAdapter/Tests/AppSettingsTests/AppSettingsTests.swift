import XCTest
import AppSettings
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

final class AppSettingsTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        let name = "app-settings-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    func testThePanesAreConnectionThenUpdates() {
        XCTAssertEqual(SettingsPane.allCases.map(\.title), ["Connexion", "Mises à jour"])
        XCTAssertEqual(SettingsPane.allCases.map(\.accessibilityID), ["hd.settings.connection", "hd.settings.updates"])
        XCTAssertEqual(SettingsCopy.checkForUpdates, "Rechercher les mises à jour…")
    }

    func testTheSettingsWindowOpensAt1024By680Points() {
        XCTAssertEqual(SettingsLayout.defaultWidth, 1024)
        XCTAssertEqual(SettingsLayout.defaultHeight, 680)
    }

    func testSavingThenReadingGivesTheSameEndpoint() {
        let defaults = isolatedDefaults()
        XCTAssertNil(SSHEndpoint.stored(in: defaults))
        let endpoint = SSHEndpoint(host: "host.example", user: "operator", port: 2200)
        endpoint.save(to: defaults)
        XCTAssertEqual(SSHEndpoint.stored(in: defaults), endpoint)
    }

    func testTheUpdatesActionStartsOneDriverCheck() {
        let driver = FakeUpdateDriver()
        let updates = UpdateCheck(driver: driver)
        UpdatesSettingsAction.perform(updates)
        UpdatesSettingsAction.perform(updates)
        XCTAssertEqual(driver.starts, 1)
        XCTAssertTrue(updates.isChecking)
    }

    func testRepeatedStoredReadsStayCheap() {
        let defaults = isolatedDefaults()
        SSHEndpoint(host: "host.example", user: "u", port: 22).save(to: defaults)
        for _ in 0..<10_000 {
            XCTAssertEqual(SSHEndpoint.stored(in: defaults)?.host, "host.example")
        }
    }
}
