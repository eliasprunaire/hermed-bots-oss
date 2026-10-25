import XCTest

/// Lanes de HD-07 contre `hv-hermes-test` : l'app atteint l'API par un tunnel SSH, jamais en direct
/// Le runner reçoit `HV_SSH_HOST`, `HV_SSH_USER`, `HV_TEST_SSH_KEY` (clé acceptée) et `HV_TEST_SSH_WRONG_KEY` (clé refusée) par `TEST_RUNNER_*`
/// `HV_API_URL` sert de référence : le test lit lui-même `/health` sur le port publié, l'app ne le reçoit pas
@MainActor
final class TunnelTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment

    override func setUpWithError() throws {
        continueAfterFailure = false
        if !name.contains("testAPersoHermesHostInTheEnvironmentNeverStartsSsh") {
            try XCTSkipIf(environment["HV_SSH_HOST"] == nil, "HV_SSH_HOST absent : pas de sshd pour le tunnel")
        }
    }

    private func launch(key: String? = nil, host: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(fr)"]
        app.launchEnvironment["HV_TEST_MODE"] = "1"
        for name in ["HV_TEST_API_KEY", "HV_TEST_API_KEYS"] { app.launchEnvironment[name] = environment[name] }
        app.launchEnvironment["HV_SSH_HOST"] = host ?? environment["HV_SSH_HOST"]
        app.launchEnvironment["HV_SSH_USER"] = environment["HV_SSH_USER"] ?? "hvssh"
        app.launchEnvironment["HV_TEST_SSH_KEY"] = key ?? environment["HV_TEST_SSH_KEY"]
        app.launch()
        return app
    }

    private func element(_ id: AccessibilityID, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id.rawValue).firstMatch
    }

    // SwiftUI expose le texte tantôt en valeur, tantôt en libellé
    private func text(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }

    private func settledVersion(in app: XCUIApplication, timeout: TimeInterval = 20) -> String {
        let version = element(.statusVersion, in: app)
        XCTAssertTrue(version.waitForExistence(timeout: timeout), "hd.status.version absent")
        let deadline = Date().addingTimeInterval(timeout)
        while ["…", "inconnue"].contains(text(of: version)), Date() < deadline { usleep(100_000) }
        return text(of: version)
    }

    private func openConnection(_ app: XCUIApplication) {
        let open = element(.connectionOpen, in: app)
        XCTAssertTrue(open.waitForExistence(timeout: 10), "hd.connection.open absent")
        open.click()
        XCTAssertTrue(element(.connectionHost, in: app).waitForExistence(timeout: 5), "la vue Connexion ne s'ouvre pas")
    }

    private func wait(for id: AccessibilityID, in app: XCUIApplication, toContain fragment: String, timeout: TimeInterval = 20) -> String {
        let target = element(id, in: app)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "\(id.rawValue) absent")
        let deadline = Date().addingTimeInterval(timeout)
        while !text(of: target).contains(fragment), Date() < deadline { usleep(100_000) }
        return text(of: target)
    }

    /// Ce que Hermes dit de lui-même sur `/health`, lu sans l'app, sur le port publié par le conteneur
    private func directVersion() -> String? {
        guard let url = environment["HV_API_URL"], let data = try? Data(contentsOf: URL(string: url + "/health")!),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return body["version"] as? String
    }

    func testTheVersionComesThroughTheTunnelNotThroughTheDirectPort() throws {
        let app = launch()
        let shown = settledVersion(in: app)
        let expected = try XCTUnwrap(directVersion(), "HV_API_URL absent ou /health illisible")
        XCTAssertEqual(shown, expected)
        openConnection(app)
        let state = wait(for: .connectionTunnelState, in: app, toContain: "ouvert")
        XCTAssertTrue(state.contains("ouvert"), state)
        XCTAssertFalse(state.contains("127.0.0.1"), state)
        print("HV-TUNNEL version=\(shown) direct=\(expected) tunnel-state=\(state)")
        HVShot.capture("hd07-tunnel", app)
    }

    func testTheConnectionViewShowsTheHostAndTheKeyStateButNeverTheKey() throws {
        let app = launch()
        _ = settledVersion(in: app)
        openConnection(app)
        let host = element(.connectionHost, in: app)
        XCTAssertEqual(text(of: host), environment["HV_SSH_HOST"])
        XCTAssertEqual(text(of: element(.connectionKeyState, in: app)), "présente dans le Trousseau")
        // aucun fragment de la clé dans tout ce que l'app expose
        let key = try XCTUnwrap(environment["HV_TEST_SSH_KEY"])
        let body = key.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        XCTAssertGreaterThan(body.count, 60)
        let tree = app.debugDescription
        for fragment in [String(body.prefix(40)), String(body.suffix(40))] {
            XCTAssertFalse(tree.contains(fragment), "un fragment de la clé est visible dans l'interface")
        }
        XCTAssertFalse(tree.contains("PRIVATE KEY"))
        HVShot.capture("hd07-connection", app)
    }

    func testAWrongKeyShowsOneClearMessageAndStopsWithoutARetryLoop() throws {
        let wrong = try XCTUnwrap(environment["HV_TEST_SSH_WRONG_KEY"], "HV_TEST_SSH_WRONG_KEY absent")
        let app = launch(key: wrong)
        let banner = wait(for: .bannerError, in: app, toContain: "refuse la clé SSH")
        XCTAssertTrue(banner.contains("Le serveur refuse la clé SSH"), banner)
        // une boucle de relance aurait changé l'état ou fait apparaître « réouverture » dans les secondes qui suivent
        sleep(6)
        XCTAssertTrue(text(of: element(.bannerError, in: app)).contains("refuse la clé SSH"))
        XCTAssertEqual(text(of: element(.statusVersion, in: app)), "inconnue")
        HVShot.capture("hd07-wrong-key", app)
        openConnection(app)
        XCTAssertEqual(text(of: element(.connectionTunnelState, in: app)), "en échec")
        XCTAssertTrue(text(of: element(.connectionMessage, in: app)).contains("refuse la clé SSH"))
    }

    func testAHostThatNamesPersoHermesIsRefusedBeforeAnyConnection() throws {
        let app = launch()
        _ = settledVersion(in: app)
        openConnection(app)
        let host = element(.connectionHost, in: app)
        host.click()
        host.typeKey("a", modifierFlags: .command)
        host.typeText("perso-hermes.invalid")
        element(.connectionConnect, in: app).click()
        let message = wait(for: .connectionMessage, in: app, toContain: "perso-hermes", timeout: 5)
        XCTAssertTrue(message.contains("refusé en mode test"), message)
        XCTAssertEqual(text(of: element(.connectionTunnelState, in: app)), "en échec")
        HVShot.capture("hd07-refuse-prod", app)
    }

    // le runner est sandboxé : il ne peut ni lancer ps ni signaler un processus (Operation not permitted)
    // Pour ces deux tests et pour le refus au lancement, `lane-processes.sh` échantillonne la table des processus pendant la passe

    func testQuittingWithCommandQClosesTheAppAndItsTunnel() throws {
        let app = launch()
        _ = settledVersion(in: app)
        // le temps à l'échantillonneur de voir le groupe vivant
        sleep(3)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "l'app ne se ferme pas")
    }

    func testTerminateClosesTheAppAndItsTunnel() throws {
        let app = launch()
        _ = settledVersion(in: app)
        sleep(3)
        app.terminate()
        XCTAssertEqual(app.state, .notRunning)
    }

    func testAPersoHermesHostInTheEnvironmentNeverStartsSsh() throws {
        let app = launch(host: "perso-hermes.invalid")
        let banner = wait(for: .bannerError, in: app, toContain: "perso-hermes", timeout: 10)
        XCTAssertTrue(banner.contains("refusé en mode test"), banner)
        // le temps à l'échantillonneur de voir qu'aucun ssh ne démarre
        sleep(4)
        XCTAssertEqual(text(of: element(.statusVersion, in: app)), "inconnue")
        HVShot.capture("hd07-refuse-launch", app)
    }
}
