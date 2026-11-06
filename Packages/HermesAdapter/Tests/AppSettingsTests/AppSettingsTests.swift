import XCTest
import AppSettings
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

final class AppSettingsTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        let name = "app-settings-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    func testThePanesAreConnectionThenAbout() {
        XCTAssertEqual(SettingsPane.allCases.map(\.title), ["Connexion", "À propos"])
        XCTAssertEqual(SettingsPane.allCases.map(\.accessibilityID), ["hd.settings.connection", "hd.settings.updates"])
        XCTAssertEqual(SettingsCopy.checkForUpdates, "Rechercher les mises à jour…")
        XCTAssertEqual(SettingsCopy.installUpdate, "Mettre à jour")
    }

    func testAboutDisplaysKnownVersions() {
        let snapshot = AboutVersionSnapshot(
            appVersion: "1.2.3",
            hermesCLI: "0.22.2",
            macOS: "27.0.1"
        )
        XCTAssertEqual(snapshot.displayedAppVersion, "1.2.3")
        XCTAssertEqual(snapshot.displayedHermesCLI, "0.22.2")
        XCTAssertEqual(snapshot.displayedMacOS, "27.0.1")
        XCTAssertEqual(AboutVersionSnapshot.macOSString(major: 27, minor: 0, patch: 1), "27.0.1")
        XCTAssertEqual(
            snapshot.versionRows.map { $0.title },
            [
                AboutVersionSnapshot.appVersionTitle,
                AboutVersionSnapshot.hermesCLITitle,
                AboutVersionSnapshot.macOSTitle,
            ]
        )
        XCTAssertFalse(snapshot.versionRows.map(\.title).contains("Build"))
        XCTAssertFalse(snapshot.versionRows.map(\.title).contains("Canal de mise à jour"))
        XCTAssertEqual(SettingsCopy.checkForUpdates, "Rechercher les mises à jour…")
        XCTAssertEqual(SettingsCopy.installUpdate, "Mettre à jour")
    }

    func testAboutDisplaysUnknownWhenAVersionIsMissingOrBlank() {
        let snapshot = AboutVersionSnapshot(appVersion: "  ", hermesCLI: nil, macOS: nil)
        XCTAssertEqual(snapshot.displayedAppVersion, "inconnue")
        XCTAssertEqual(snapshot.displayedHermesCLI, "inconnue")
        XCTAssertEqual(snapshot.displayedMacOS, "inconnue")
        XCTAssertEqual(AboutVersionSnapshot.display(nil), "inconnue")
        XCTAssertEqual(AboutVersionSnapshot.display(""), "inconnue")
        XCTAssertEqual(AboutVersionSnapshot.unknownLabel, "inconnue")
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

    func testTheInstallActionStartsTheDriverOnlyWhenAnUpdateIsAvailable() {
        let driver = FakeUpdateDriver()
        let updates = UpdateCheck(driver: driver)
        UpdatesSettingsAction.install(updates)
        XCTAssertEqual(driver.installs, 0)
        UpdatesSettingsAction.perform(updates)
        updates.noteAvailable(version: "0.1.9")
        updates.noteSessionEnded()
        UpdatesSettingsAction.install(updates)
        XCTAssertEqual(driver.installs, 1)
        XCTAssertEqual(driver.starts, 1)
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

    func testEphemeralModeOverlaysASessionFileDumpToAgent() {
        let launch = SSHLaunchIdentity.overlay(
            mode: .ephemeralAgent,
            sessionKind: .file,
            sessionPresent: false,
            keyCommandSet: true,
            hasExternalIdentityAgent: false
        )
        XCTAssertEqual(launch.kind, .agent)
        XCTAssertTrue(launch.present)
        XCTAssertEqual(SSHLaunchIdentityKind.agent.rawValue, "agent")
        XCTAssertFalse(SSHLaunchIdentityKind.agent.rawValue.contains("/tmp"))
    }

    func testSessionModeKeepsTheFileIdentityFromTheDump() {
        let launch = SSHLaunchIdentity.overlay(
            mode: .sessionAgent,
            sessionKind: .file,
            sessionPresent: false,
            keyCommandSet: false,
            hasExternalIdentityAgent: false
        )
        XCTAssertEqual(launch.kind, .file)
        XCTAssertFalse(launch.present)
    }

    func testWrapperModeLeavesTheIdentityToTheExecutable() {
        for sessionKind in [SSHLaunchIdentityKind.file, .certificate, .agent] {
            let launch = SSHLaunchIdentity.overlay(
                mode: .wrapper,
                sessionKind: sessionKind,
                sessionPresent: false,
                keyCommandSet: false,
                hasExternalIdentityAgent: false
            )
            XCTAssertEqual(launch.kind, .executable, "\(sessionKind)")
            XCTAssertTrue(launch.present, "\(sessionKind)")
        }
        XCTAssertEqual(SSHLaunchIdentityKind.executable.rawValue, "executable")
        XCTAssertTrue(SSHLaunchIdentity.allows(.executable, launch: .wrapper))
        XCTAssertFalse(SSHLaunchIdentity.allows(.executable, launch: .ephemeralAgent))
    }

    func testEphemeralPresenceFollowsKeyCommandOrExternalAgent() {
        let missing = SSHLaunchIdentity.overlay(
            mode: .ephemeralAgent,
            sessionKind: .file,
            sessionPresent: true,
            keyCommandSet: false,
            hasExternalIdentityAgent: false
        )
        XCTAssertEqual(missing.kind, .agent)
        XCTAssertFalse(missing.present)
        let external = SSHLaunchIdentity.overlay(
            mode: .ephemeralAgent,
            sessionKind: .file,
            sessionPresent: false,
            keyCommandSet: false,
            hasExternalIdentityAgent: true
        )
        XCTAssertTrue(external.present)
        XCTAssertTrue(SSHLaunchIdentity.identityAgentIsExternal("/tmp/fake-agent.invalid"))
        XCTAssertFalse(SSHLaunchIdentity.identityAgentIsExternal("none"))
        XCTAssertFalse(SSHLaunchIdentity.identityAgentIsExternal("SSH_AUTH_SOCK"))
        XCTAssertFalse(SSHLaunchIdentity.identityAgentIsExternal(nil))
    }

    func testAuthModeChoicePrefersAnExplicitPickerValue() {
        XCTAssertEqual(
            SSHAuthModeChoice.selected(
                userChose: true,
                stored: .sessionAgent,
                keyCommandSet: false,
                hasExternalIdentityAgent: true
            ),
            .sessionAgent
        )
    }

    func testAuthModeChoiceDefaultsToEphemeralWhenAnExternalAgentIsPresent() {
        XCTAssertEqual(
            SSHAuthModeChoice.selected(
                userChose: false,
                stored: .sessionAgent,
                keyCommandSet: false,
                hasExternalIdentityAgent: true
            ),
            .ephemeralAgent
        )
        XCTAssertEqual(
            SSHAuthModeChoice.selected(
                userChose: false,
                stored: .sessionAgent,
                keyCommandSet: false,
                hasExternalIdentityAgent: false
            ),
            .sessionAgent
        )
    }

    func testAuthModeChoiceKeepsEphemeralWhenAKeyCommandIsSet() {
        XCTAssertEqual(
            SSHAuthModeChoice.selected(
                userChose: false,
                stored: .ephemeralAgent,
                keyCommandSet: true,
                hasExternalIdentityAgent: false
            ),
            .ephemeralAgent
        )
    }

    func testClassifyNamesTheFourFailuresFromStderrAndStatus() {
        XCTAssertEqual(
            SSHExitClassification.kind(
                stderr: "ssh: connect to host gateway.invalid port 22: Connection refused\n",
                status: 255
            ),
            .hostUnreachable
        )
        XCTAssertEqual(
            SSHExitClassification.kind(
                stderr: "operator@gateway.invalid: Permission denied (publickey).",
                status: 255
            ),
            .authRefused
        )
        XCTAssertEqual(
            SSHExitClassification.kind(
                stderr: "Error connecting to agent: No such file or directory",
                status: 255
            ),
            .agentUnavailable
        )
        XCTAssertEqual(
            SSHExitClassification.kind(
                stderr: "The agent has no identities.",
                status: 255
            ),
            .missingKey
        )
        XCTAssertEqual(
            SSHExitClassification.kind(
                stderr: "Connection reset by peer",
                status: 255
            ),
            .tunnelClosed
        )
        XCTAssertEqual(SSHExitClassification.kind(stderr: "", status: 1), .tunnelClosed)
        XCTAssertEqual(SSHExitClassification.kind(stderr: "", status: 255), .hostUnreachable)
    }

    func testSSHStageExit255ShowsTheGenericHermesMessageAndStripsHostPathAndUser() {
        let stderr = """
        ssh: connect to host example.invalid port 22: Connection refused
        ssh: connect to host 203.0.113.10 port 22: Network is unreachable
        Identity file /opt/example/id_ed25519 not accessible
        operator@example.invalid: Network is unreachable
        """
        let report = SSHExitClassification.make(stderr: stderr, status: 255)
        XCTAssertEqual(report.stage, SSHExitClassification.sshStage)
        XCTAssertEqual(report.fallback, .hostUnreachable)
        XCTAssertEqual(report.reason, "exit-255")
        XCTAssertEqual(report.displayedMessage, "la machine Hermes ne répond pas")
        let shown = report.displayedMessage ?? ""
        XCTAssertFalse(shown.contains("example.invalid"), shown)
        XCTAssertFalse(shown.contains("/opt/example"), shown)
        XCTAssertFalse(shown.contains("operator@"), shown)
        XCTAssertFalse(shown.contains("Connection refused"), shown)
        XCTAssertFalse(shown.contains("203.0.113."), shown)
        XCTAssertEqual(shown, SSHExitClassification.hermesUnreachableMessage)
    }

    func testSSHConnectionTimeoutShowsTheGenericHermesMessage() {
        let stderr = "ssh: connect to host example.invalid port 22: Operation timed out\nuser@example.invalid"
        let report = SSHExitClassification.make(stderr: stderr, status: 255, timedOut: true)
        XCTAssertEqual(report.stage, SSHExitClassification.sshStage)
        XCTAssertEqual(report.fallback, .hostUnreachable)
        XCTAssertEqual(report.reason, "timeout")
        XCTAssertEqual(report.displayedMessage, "la machine Hermes ne répond pas")
        let shown = report.displayedMessage ?? ""
        XCTAssertFalse(shown.contains("example.invalid"), shown)
        XCTAssertFalse(shown.contains("user@"), shown)
        XCTAssertFalse(shown.contains("timed out"), shown)
    }

    func testAnotherStatusOrStageKeepsCurrentClassificationWithoutTheGenericMessage() {
        XCTAssertNil(SSHExitClassification.make(stderr: "boom", status: 7).displayedMessage)
        XCTAssertEqual(SSHExitClassification.make(stderr: "boom", status: 7).fallback, .hostUnreachable)
        XCTAssertEqual(SSHExitClassification.make(stderr: "boom", status: 7).reason, "exit-7")
        XCTAssertEqual(SSHExitClassification.make(stderr: "boom", status: 7).stage, SSHExitClassification.sshStage)

        let auth = SSHExitClassification.make(stderr: "operator@example.invalid: Permission denied (publickey).", status: 255)
        XCTAssertEqual(auth.stage, SSHExitClassification.sshStage)
        XCTAssertEqual(auth.fallback, .authRefused)
        XCTAssertNil(auth.displayedMessage)
        XCTAssertEqual(SSHExitClassification.kind(stderr: "operator@example.invalid: Permission denied (publickey).", status: 255), .authRefused)

        let closed = SSHExitClassification.make(stderr: "Connection reset by peer", status: 255)
        XCTAssertEqual(closed.stage, "tunnel")
        XCTAssertEqual(closed.fallback, .tunnelClosed)
        XCTAssertNil(closed.displayedMessage)

        let wrapper = SSHExitClassification.make(stderr: "gate-wrapper_failure=17\n", status: 255)
        XCTAssertEqual(wrapper.stage, "wrapper")
        XCTAssertEqual(wrapper.fallback, .wrapperFailure)
        XCTAssertNil(wrapper.displayedMessage)
    }

    func testAWrapperFailureLineIsNamedWhateverThePrecedingStderrSays() {
        let line = "gate-wrapper_failure=17"
        XCTAssertEqual(
            SSHExitClassification.wrapperFailure(stderr: line + "\n"),
            SSHWrapperFailure(name: "gate-wrapper", code: "17")
        )
        XCTAssertEqual(
            SSHExitClassification.wrapperFailure(stderr: "debug: starting\n\(line) (see log)\nPermission denied (publickey).\n"),
            SSHWrapperFailure(name: "gate-wrapper", code: "17")
        )
        XCTAssertEqual(
            SSHExitClassification.wrapperFailure(stderr: "relay.v2_failure=host_down:3\n"),
            SSHWrapperFailure(name: "relay.v2", code: "host_down:3")
        )
        // la ligne du wrapper l'emporte sur les phrases d'OpenSSH et sur le repli « injoignable »
        for status: Int32 in [1, 255] {
            XCTAssertEqual(SSHExitClassification.kind(stderr: "Permission denied (publickey).\n\(line)\n", status: status), .wrapperFailure)
            XCTAssertEqual(SSHExitClassification.kind(stderr: line, status: status), .wrapperFailure)
        }
    }

    func testOnlyAWellFormedKeyValueLineIsAWrapperFailure() {
        for stderr in [
            "",
            "Permission denied (publickey).",
            "_failure=3",
            "gate_failure=",
            "gate_failure",
            "gate failure=3",
            "gate_failure=a=b",
            "-gate_failure=3",
            "gate/x_failure=3",
            "gate_failure=\(String(repeating: "9", count: 33))",
            "\(String(repeating: "a", count: 65))_failure=3",
        ] {
            XCTAssertNil(SSHExitClassification.wrapperFailure(stderr: stderr), stderr)
            XCTAssertNotEqual(SSHExitClassification.kind(stderr: stderr, status: 255), .wrapperFailure, stderr)
        }
    }

    func testTenThousandClassificationsStayCheap() {
        for _ in 0..<10_000 {
            XCTAssertEqual(
                SSHExitClassification.kind(stderr: "Permission denied (publickey).", status: 255),
                .authRefused
            )
        }
    }

    func testPreviewLockKeepsEphemeralIdentityWhenThePickerMovesToSession() {
        XCTAssertEqual(
            SSHLaunchIdentity.overlayMode(picker: .sessionAgent, launch: .ephemeralAgent),
            .ephemeralAgent
        )
        let launch = SSHLaunchIdentity.overlay(
            mode: SSHLaunchIdentity.overlayMode(picker: .sessionAgent, launch: .ephemeralAgent),
            sessionKind: .file,
            sessionPresent: false,
            keyCommandSet: true,
            hasExternalIdentityAgent: false
        )
        XCTAssertEqual(launch.kind, .agent)
        XCTAssertFalse(SSHLaunchIdentity.allows(.file, launch: .ephemeralAgent))
        XCTAssertTrue(SSHLaunchIdentity.allows(.agent, launch: .ephemeralAgent))
        XCTAssertTrue(SSHLaunchIdentity.allows(.file, launch: .sessionAgent))
        XCTAssertTrue(SSHLaunchIdentity.allows(.file, launch: nil))
        XCTAssertEqual(SSHLaunchIdentityKind.agent.rawValue, "agent")
        XCTAssertEqual(SSHLaunchIdentityKind.file.rawValue, "file")
        XCTAssertEqual(SSHLaunchIdentityKind.certificate.rawValue, "certificate")
    }

    func testTenThousandOverlaysStayCheap() {
        for _ in 0..<10_000 {
            let launch = SSHLaunchIdentity.overlay(
                mode: .ephemeralAgent,
                sessionKind: .file,
                sessionPresent: false,
                keyCommandSet: true,
                hasExternalIdentityAgent: false
            )
            XCTAssertEqual(launch.kind, .agent)
        }
    }
}
