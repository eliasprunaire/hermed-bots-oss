import XCTest

/// Sonde de perf de HD-08 : lancement jusqu'à ce que chaque ligne de bot soit visible, puis dépli d'un bot de 200 fils
/// Cinq mesures de chaque, chacune sur un lancement à froid ; budgets du plan : médiane de 1,5 s au lancement, de 500 ms au dépli
/// Les budgets sont des propositions du plan, pas des mesures de référence
/// Le dépli se mesure du tap reçu par l'app à la dernière ligne visible : le `click()` de XCUITest met environ 400 ms à livrer le tap, un délai du test et non de l'app
/// Le total de bout en bout s'imprime à côté (`end_to_end_ms`) pour que personne ne le perde de vue
@MainActor
final class BotsPerfProbe: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(fr)"]
        app.launchEnvironment["HV_TEST_MODE"] = "1"
        app.launchEnvironment["HV_API_URL"] = environment["HV_API_URL"]
        for name in ["HV_TEST_API_KEY", "HV_TEST_API_KEYS"] { app.launchEnvironment[name] = environment[name] }
        app.launch()
        return app
    }

    private func rows(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES %@", #"hd\.bots\.row\.[^.]+"#))
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    /// L'heure à laquelle le faux serveur a reçu la requête, lue dans son journal ; nil sans journal
    private func requestTime(of path: String, after: Date) -> Date? {
        guard let base = environment["HV_API_URL"], let url = URL(string: base + "/_hv/log"), let data = try? Data(contentsOf: url),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return entries.compactMap { entry -> Date? in
            guard entry["probe"] as? Bool != true, entry["p"] as? String == path, let time = entry["t"] as? Double else { return nil }
            let date = Date(timeIntervalSince1970: time)
            return date >= after ? date : nil
        }.min()
    }

    private func median(_ values: [Int]) -> Int { values.sorted()[values.count / 2] }

    func testLaunchToEveryBotRowVisible() throws {
        let wanted = Int(environment["HV_EXPECT_BOT_COUNT"] ?? "") ?? 0
        try XCTSkipIf(wanted == 0, "HV_EXPECT_BOT_COUNT absent : pas de serveur à neuf profils à mesurer")
        var samples: [Int] = []
        for run in 1...5 {
            let start = ContinuousClock.now
            let app = launch()
            let deadline = Date().addingTimeInterval(30)
            while rows(in: app).count < wanted, Date() < deadline { usleep(10_000) }
            let ms = milliseconds(since: start)
            XCTAssertEqual(rows(in: app).count, wanted, "lancement \(run) : toutes les lignes ne sont pas visibles")
            samples.append(ms)
            print("HV-PERF08 launch run=\(run) rows=\(wanted) ms=\(ms)")
            app.terminate()
        }
        print("HV-PERF08 launch median_ms=\(median(samples)) runs=\(samples) budget_ms=1500")
        XCTAssertLessThanOrEqual(median(samples), 1500)
    }

    func testExpandingABotWithTwoHundredThreads() throws {
        let bot = environment["HV_EXPAND_BOT"] ?? ""
        let last = environment["HV_EXPECT_LAST_THREAD"] ?? ""
        try XCTSkipIf(bot.isEmpty || last.isEmpty, "HV_EXPAND_BOT ou HV_EXPECT_LAST_THREAD absent : pas de bot à 200 fils")
        var endToEnd: [Int] = []
        var shown: [Int] = []
        for run in 1...5 {
            let app = launch()
            // une requête typée : la requête `.any` fait lire tout l'arbre d'accessibilité au clic, ce qui coûte plus que l'action
            let row = app.buttons[AccessibilityID.botRow(bot)]
            XCTAssertTrue(row.waitForExistence(timeout: 30), "dépli \(run) : \(bot) absent")
            let target = app.staticTexts[AccessibilityID.threadRow(last)]
            let start = ContinuousClock.now
            let clickedAt = Date()
            row.click()
            let deadline = Date().addingTimeInterval(30)
            while !target.exists, Date() < deadline { usleep(5_000) }
            let ms = milliseconds(since: start)
            XCTAssertTrue(target.exists, "dépli \(run) : \(last) n'apparaît pas")
            // la requête part 2 ms après le tap : elle date le tap reçu par l'app
            let requestedAt = try XCTUnwrap(requestTime(of: "/p/\(bot)/api/sessions", after: clickedAt), "dépli \(run) : le serveur n'a reçu aucune requête de fils")
            let delivery = Int(requestedAt.timeIntervalSince(clickedAt) * 1000)
            endToEnd.append(ms)
            shown.append(ms - delivery)
            print("HV-PERF08 expand run=\(run) bot=\(bot) last=\(last) end_to_end_ms=\(ms) click_to_request_ms=\(delivery) request_to_visible_ms=\(ms - delivery)")
            app.terminate()
        }
        print("HV-PERF08 expand end_to_end_median_ms=\(median(endToEnd)) runs=\(endToEnd)")
        print("HV-PERF08 expand median_ms=\(median(shown)) runs=\(shown) budget_ms=500")
        XCTAssertLessThanOrEqual(median(shown), 500)
    }
}
