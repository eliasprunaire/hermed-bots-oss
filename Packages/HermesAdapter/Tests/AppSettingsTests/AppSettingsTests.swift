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

    func testTheSettingsLayoutDefaultSizeIs1024By680Points() {
        XCTAssertEqual(SettingsLayout.defaultWidth, 1024)
        XCTAssertEqual(SettingsLayout.defaultHeight, 680)
    }

    func testSavingThenReadingGivesTheSameEndpoint() {
        let defaults = isolatedDefaults()
        XCTAssertNil(SSHEndpoint.stored(in: defaults))
        let endpoint = SSHEndpoint(host: "lab.invalid")
        endpoint.save(to: defaults)
        XCTAssertEqual(SSHEndpoint.stored(in: defaults), endpoint)
    }

    func testAnOldHostOnlyStoreDefaultsToTheSessionAgent() {
        let defaults = isolatedDefaults()
        defaults.set("lab.invalid", forKey: "ssh.host")
        let stored = SSHEndpoint.stored(in: defaults)
        XCTAssertEqual(stored?.authMode, .sessionAgent)
        XCTAssertEqual(stored?.wrapperPath, "")
        XCTAssertEqual(stored?.keyCommandPath, "")
    }

    func testAuthModeAndToolPathsRoundTripWithoutASecret() {
        let defaults = isolatedDefaults()
        let endpoint = SSHEndpoint(
            host: "lab.invalid",
            authMode: .ephemeralAgent,
            wrapperPath: "/tmp/example-wrapper.invalid",
            keyCommandPath: "/tmp/example-key-command.invalid"
        )
        endpoint.save(to: defaults)
        XCTAssertEqual(SSHEndpoint.stored(in: defaults), endpoint)
        XCTAssertEqual(SSHAuthMode.allCases.map(\.label), ["Agent de session", "Agent temporaire", "Exécutable"])
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
        SSHEndpoint(host: "lab.invalid").save(to: defaults)
        for _ in 0..<10_000 {
            XCTAssertEqual(SSHEndpoint.stored(in: defaults)?.host, "lab.invalid")
        }
    }

    func testAnAliasWithANonDefaultPortShowsTheResolvedPortFromSSHConfig() {
        let port = SSHDisplayedPort.readOnly(resolvedPort: 2200)
        XCTAssertEqual(port.number, 2200)
        XCTAssertTrue(port.fromSSHConfig)
        XCTAssertEqual(port.settingsTitle, "Port (config SSH)")
        XCTAssertEqual(port.settingsValue, "2200")
        XCTAssertEqual(port.statusText, "Port SSH 2200 (config SSH)")
    }

    func testAnAliasWithoutAPortKeepsTheDumpValueAsComingFromSSHConfig() {
        let port = SSHDisplayedPort.readOnly(resolvedPort: SSHDisplayedPort.fallback)
        XCTAssertEqual(port.number, SSHDisplayedPort.fallback)
        XCTAssertTrue(port.fromSSHConfig)
        XCTAssertEqual(port.settingsTitle, "Port (config SSH)")
        XCTAssertEqual(port.statusText, "Port SSH \(SSHDisplayedPort.fallback) (config SSH)")
    }

    func testAFailedResolutionKeepsTheDefaultPortSetting() {
        let port = SSHDisplayedPort.readOnly(resolvedPort: nil)
        XCTAssertEqual(port.number, SSHDisplayedPort.fallback)
        XCTAssertFalse(port.fromSSHConfig)
        XCTAssertEqual(port.settingsTitle, "Port")
        XCTAssertEqual(port.settingsValue, String(SSHDisplayedPort.fallback))
        XCTAssertEqual(port.statusText, "Port SSH \(SSHDisplayedPort.fallback)")
    }
}
