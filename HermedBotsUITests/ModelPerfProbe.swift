import XCTest

/// Sonde de perf de HD-10 : dix changements de modèle, du clic sur l'option au modèle confirmé dans le sélecteur, en mode `normal`
/// Critère révisé et approuvé par Dev Lead le 20/10 à 12:03 (PR #40) : l'horloge de l'app (`hd.perf.model`, un point sans pixel du mode test, build Debug) part à `pick(model:)` et s'arrête quand le sélecteur montre le modèle confirmé ; la médiane des dix changements est de 500 ms au plus
/// La durée de bout en bout (`end_to_end_ms`, de `click()` au modèle lu dans le sélecteur) s'imprime à titre d'information et n'est pas jugée : le `click()` de XCUITest met lui-même environ 500 ms à livrer un clic sur une zone neutre de la fenêtre, et plus de 1 s sur une option de menu
/// Au trunk il n'y a pas de sélecteur : rien à chronométrer, le budget est absolu
@MainActor
final class ModelPerfProbe: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment

    override func setUp() {
        continueAfterFailure = false
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
            guard entry["m"] as? String == "POST", entry["p"] as? String == path, let time = entry["t"] as? Double else { return nil }
            let date = Date(timeIntervalSince1970: time)
            return date >= after ? date : nil
        }.min()
    }

    private func median(_ values: [Int]) -> Int { values.sorted()[values.count / 2] }

    /// Les durées que l'app a mesurées elle-même, dans l'ordre des changements
    private func appDurations(_ probe: XCUIElement) -> [Int] {
        probe.label.split(separator: ",").compactMap { Int($0) }
    }

    func testTenSwitchesFromTheOptionClickToTheConfirmedModel() throws {
        let base = try XCTUnwrap(environment["HV_API_URL"], "HV_API_URL absent")
        try XCTSkipUnless(
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: XCTUnwrap(URL(string: base + "/_hv/ready")))) as? [String: Any])?["mode"] as? String == "normal",
            "le faux serveur n'est pas en mode normal"
        )
        FakeServer.reset()
        FakeServer.setProfileModels(["hv-bot-b": "model-y"])
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(fr)"]
        app.launchEnvironment["HV_TEST_MODE"] = "1"
        for name in ["HV_API_URL", "HV_TEST_API_KEY", "HV_TEST_API_KEYS"] {
            if let value = environment[name] { app.launchEnvironment[name] = value }
        }
        app.launch()

        func element(_ id: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", id)).firstMatch
        }
        func shown(_ element: XCUIElement) -> String {
            if let value = element.value as? String, !value.isEmpty { return value }
            return element.label
        }

        let bot = element(AccessibilityID.botRow("hv-bot-a"))
        XCTAssertTrue(bot.waitForExistence(timeout: 20), "hd.bots.row.hv-bot-a absent")
        let hittable = Date().addingTimeInterval(10)
        while !bot.isHittable, Date() < hittable { usleep(50_000) }
        bot.click()
        let thread = element(AccessibilityID.threadRow("s-past-1"))
        XCTAssertTrue(thread.waitForExistence(timeout: 10), "hd.threads.row.s-past-1 absent")
        thread.click()
        let picker = element(AccessibilityID.modelPicker.rawValue)
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "hd.model.picker absent")
        XCTAssertEqual(shown(picker), "hv-fake-1")

        let probe = element(AccessibilityID.perfModel.rawValue)
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "hd.perf.model absent : l'app n'est pas un build Debug en mode test")
        XCTAssertEqual(appDurations(probe), [], "aucune mesure avant le premier changement")

        // un clic sur une zone neutre de la fenêtre, sans menu ouvert ni travail de l'app : le plancher du `click()` de XCUITest
        var neutral: [Int] = []
        for _ in 1...3 {
            let start = ContinuousClock.now
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).click()
            neutral.append(milliseconds(since: start))
        }
        print("HV-PERF10 neutral_click median_ms=\(median(neutral)) runs=\(neutral) (plancher de click() de XCUITest, sans travail de l'app)")

        let path = "/p/hv-bot-a/api/sessions/s-past-1/model"
        var endToEnd: [Int] = []
        for run in 1...10 {
            // un changement sur deux revient au modèle du profil : chaque choix est un vrai `set_model`
            let target = run.isMultiple(of: 2) ? "hv-fake-1" : "model-y"
            picker.click()
            let option = element(AccessibilityID.modelOption(target))
            XCTAssertTrue(option.waitForExistence(timeout: 5), "changement \(run) : hd.model.option.\(target) absent")
            let start = ContinuousClock.now
            let clickedAt = Date()
            option.click()
            let returnedAt = Date()
            let deadline = Date().addingTimeInterval(15)
            while shown(picker) != target, Date() < deadline { usleep(2_000) }
            let ms = milliseconds(since: start)
            XCTAssertEqual(shown(picker), target, "changement \(run) : le sélecteur ne montre pas \(target)")
            let measured = Date().addingTimeInterval(5)
            while appDurations(probe).count < run, Date() < measured { usleep(10_000) }
            XCTAssertEqual(appDurations(probe).count, run, "changement \(run) : l'app n'a pas mesuré le changement")
            let requestedAt = try XCTUnwrap(requestTime(of: path, after: clickedAt), "changement \(run) : le serveur n'a reçu aucun set_model")
            let delivery = Int(requestedAt.timeIntervalSince(clickedAt) * 1000)
            // positif : le serveur a reçu `set_model` avant que `click()` rende la main, donc le délai du clic est dans XCUITest et non dans l'app
            let requestBeforeReturn = Int(returnedAt.timeIntervalSince(requestedAt) * 1000)
            endToEnd.append(ms)
            print("HV-PERF10 switch run=\(run) target=\(target) app_click_to_confirmed_ms=\(appDurations(probe)[run - 1]) end_to_end_ms=\(ms) click_to_request_ms=\(delivery) request_before_click_returns_ms=\(requestBeforeReturn)")
        }
        let inApp = appDurations(probe)
        print("HV-PERF10 switch end_to_end_median_ms=\(median(endToEnd)) runs=\(endToEnd) (XCUITest, de click() au modèle lu dans le sélecteur, information, non jugée)")
        print("HV-PERF10 switch median_ms=\(median(inApp)) runs=\(inApp) budget_ms=500 (horloge de l'app, de pick(model:) au modèle confirmé, jugée)")
        XCTAssertEqual(endToEnd.count, 10)
        XCTAssertEqual(inApp.count, 10)
        XCTAssertLessThanOrEqual(median(inApp), 500, "critère approuvé : médiane de l'horloge de l'app, de pick(model:) au modèle confirmé")
    }
}
