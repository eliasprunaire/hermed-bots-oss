import XCTest

@MainActor
final class LaunchTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment
    private var apiURL: String? { environment["HV_API_URL"] }

    override func setUp() {
        continueAfterFailure = false
    }

    /// Lance l'app en mode test ; `url` remplace `HV_API_URL` du runner
    private func launch(language: String = "fr", url: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(\(language))"]
        app.launchEnvironment["HV_TEST_MODE"] = "1"
        if let url = url ?? apiURL { app.launchEnvironment["HV_API_URL"] = url }
        for name in ["HV_TEST_API_KEY", "HV_TEST_API_KEYS"] { app.launchEnvironment[name] = environment[name] }
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

    /// Ce que Hermes dit de lui-même sur `/health`, lu sans l'app : la référence à laquelle l'app se compare
    private func serverVersion(at url: String?) -> String? {
        guard let url, let data = try? Data(contentsOf: URL(string: url + "/health")!),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = body["version"] as? String, !version.isEmpty else { return nil }
        return version
    }

    /// Attend que `hd.status.version` quitte l'état de chargement et rend son texte
    private func settledVersion(in app: XCUIApplication, timeout: TimeInterval = 15) -> String {
        let version = element(.statusVersion, in: app)
        XCTAssertTrue(version.waitForExistence(timeout: timeout), "hd.status.version absent")
        let deadline = Date().addingTimeInterval(timeout)
        while text(of: version) == "…", Date() < deadline { usleep(50_000) }
        return text(of: version)
    }

    private func note(_ message: String) {
        let stamp = DateFormatter()
        stamp.timeZone = TimeZone(identifier: "Europe/Paris")
        stamp.dateFormat = "HH:mm:ss"
        let line = "[\(stamp.string(from: Date())) Paris] \(message)\n"
        print(line, terminator: "")
        guard let log = HVShot.directory?.deletingLastPathComponent().appendingPathComponent("run.log"),
              let handle = try? FileHandle(forWritingTo: log) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    func testWindowOpensWithTheServerVersionAndTheBotList() {
        let app = launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "la fenêtre ne s'ouvre pas")
        let shown = settledVersion(in: app)
        let expected = serverVersion(at: apiURL) ?? "inconnue"
        XCTAssertEqual(shown, expected)
        note("HV-LAUNCH hd.status.version=\(shown) serveur=\(expected)")
        XCTAssertTrue(element(.botsList, in: app).exists, "hd.bots.list absent")
        // un identifiant désigne un seul élément : un conteneur ne le passe pas à ses enfants
        for id in [AccessibilityID.botsList, AccessibilityID.statusVersion] {
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: id.rawValue).count, 1, "\(id.rawValue) désigne plus d'un élément")
        }
        HVShot.capture("launch", app)
    }

    func testVersionIsUnknownWhenNothingListens() {
        let app = launch(url: "http://127.0.0.1:1")
        XCTAssertEqual(settledVersion(in: app), "inconnue")
        XCTAssertEqual(text(of: element(.bannerError, in: app)), "Hermes ne répond pas. Vérifiez la liaison puis réessayez.")
        HVShot.capture("unreachable", app)
    }

    func testEveryIdStaysTheSameInFrenchAndEnglish() {
        var idsByLanguage: [String: Set<String>] = [:]
        for language in ["fr", "en"] {
            let app = launch(language: language)
            let shown = settledVersion(in: app)
            // les lignes de bot arrivent après la version : on attend la première quand le serveur répond
            if serverVersion(at: apiURL) != nil {
                _ = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'hd.bots.row.'")).firstMatch.waitForExistence(timeout: 10)
            }
            // seuls les `hd.*` sont énumérés : une infobulle ou un autre élément sans identifiant décalerait l'index de la liste complète
            let all = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'hd.'")).allElementsBoundByIndex
            idsByLanguage[language] = Set(all.map { $0.identifier })
            HVShot.capture("language-\(language)", app)
            note("HV-LANG \(language) ids=\(idsByLanguage[language]!.sorted()) hd.status.version=\(shown)")
            app.terminate()
        }
        XCTAssertEqual(idsByLanguage["fr"], idsByLanguage["en"])
        XCTAssertTrue(idsByLanguage["fr"]!.isSuperset(of: [AccessibilityID.botsList.rawValue, AccessibilityID.statusVersion.rawValue]))
    }

    func testTenLaunchesInARowShowTheWindow() {
        for run in 1...10 {
            let app = launch()
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "lancement \(run) : pas de fenêtre")
            XCTAssertNotEqual(app.state, .notRunning)
            note("HV-RELAUNCH run=\(run) window=ok")
            app.terminate()
        }
    }

    // budget de 2 s sur la médiane : une proposition du plan, pas une mesure de référence
    func testColdLaunchToVersionVisibleStaysUnderTwoSeconds() throws {
        guard let expected = serverVersion(at: apiURL) else { throw XCTSkip("HV_API_URL doit pointer un Hermes qui répond pour mesurer") }
        var millis: [Int] = []
        for run in 1...5 {
            let start = Date()
            let app = launch()
            XCTAssertEqual(settledVersion(in: app), expected)
            millis.append(Int(Date().timeIntervalSince(start) * 1000))
            note("HV-PERF cold-launch run=\(run) ms=\(millis.last!)")
            app.terminate()
        }
        let median = millis.sorted()[millis.count / 2]
        note("HV-PERF median_ms=\(median) runs=\(millis) budget_ms=2000")
        XCTAssertLessThanOrEqual(median, 2000)
    }
}
