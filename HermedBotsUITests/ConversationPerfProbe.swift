import AppKit
import XCTest

/// Sonde de perf de HD-09 : le délai entre un `message.delta` émis et son texte à l'écran, puis le blocage du fil principal de l'app pendant l'envoi de 100 000 caractères
/// Le trunk n'a ni vue de conversation ni champ de saisie : les deux budgets sont absolus, pas relatifs à une mesure du trunk
/// Les budgets sont des propositions du plan (95e centile du délai de 300 ms, aucun blocage de plus de 250 ms), pas des mesures de référence
/// Le délai se lit à l'écran par l'accessibilité : chaque lecture coûte quelques dizaines de ms, ce qui majore le délai mesuré
/// Le blocage ne se lit pas du dehors : `typeKey` et `click` attendent eux-mêmes le retour de l'app au repos, donc un blocage qu'ils absorbent échappe à tout chronomètre du runner
/// Le chien de garde de l'app (`MainThreadWatch`, mode test) date chaque blocage de 50 ms ou plus ; la sonde garde ceux qui recouvrent la fenêtre du collage et de l'envoi
@MainActor
final class ConversationPerfProbe: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment
    private var apiURL: String? { environment["HV_API_URL"] }

    // un test qui a échoué avant sa fin a laissé ses événements injectés : chaque test repart d'un flux sans eux
    override func setUp() {
        continueAfterFailure = false
        FakeServer.reset()
    }

    private func launch(_ extra: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(fr)"]
        app.launchEnvironment["HV_TEST_MODE"] = "1"
        app.launchEnvironment["HV_API_URL"] = environment["HV_API_URL"]
        for name in ["HV_TEST_API_KEY", "HV_TEST_API_KEYS"] { app.launchEnvironment[name] = environment[name] }
        for (name, value) in extra { app.launchEnvironment[name] = value }
        app.launch()
        return app
    }

    private func data(_ path: String) -> Data? {
        guard let apiURL, let url = URL(string: apiURL + path) else { return nil }
        return try? Data(contentsOf: url)
    }

    private func post(_ path: String, _ body: [String: Any] = [:]) {
        guard let apiURL, let url = URL(string: apiURL + path) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        done.wait()
    }

    private func isFakeServer() -> Bool {
        guard let ready = data("/_hv/ready"), (try? JSONSerialization.jsonObject(with: ready)) != nil else { return false }
        return true
    }

    private func element(_ id: AccessibilityID, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", id.rawValue)).firstMatch
    }

    private func openBot(in app: XCUIApplication) {
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", AccessibilityID.botRow("hv-bot-a"))).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "hd.bots.row.hv-bot-a absent")
        // la liste existe avant que ses lignes aient une place à l'écran : un clic trop tôt ne trouve pas de point à cliquer
        let hittable = Date().addingTimeInterval(10)
        while !row.isHittable, Date() < hittable { usleep(50_000) }
        row.click()
        XCTAssertTrue(element(.composerInput, in: app).waitForExistence(timeout: 10), "hd.composer.input absent")
    }

    private func milliseconds(_ interval: TimeInterval) -> Int { Int((interval * 1000).rounded()) }

    private func percentile(_ values: [Int], _ fraction: Double) -> Int {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count) * fraction).rounded(.up)) - 1)]
    }

    /// Le texte de la dernière ligne de la conversation, la réponse en cours : quelques lectures seulement à chaque appel, pour ne pas ralentir la mesure
    private func lastMessageText(in app: XCUIApplication) -> String? {
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "hd.conversation.message."))
        let count = rows.count
        guard count > 0 else { return nil }
        let last = rows.element(boundBy: count - 1)
        return last.value as? String ?? last.label
    }

    /// Le moment où le faux serveur a écrit chaque `message.delta` dans le flux, par texte de delta
    private func emissionTimes(since: Date) -> [String: TimeInterval] {
        guard let log = data("/_hv/log"), let entries = try? JSONSerialization.jsonObject(with: log) as? [[String: Any]] else { return [:] }
        var times: [String: TimeInterval] = [:]
        for entry in entries where entry["p"] as? String == "/_hv/sse/message.delta" {
            guard let time = entry["t"] as? Double, time >= since.timeIntervalSince1970, let body = entry["body"] as? String else { continue }
            times[body] = times[body] ?? time
        }
        return times
    }

    /// 20 deltas injectés dans un tour : chacun a son texte, repéré à l'écran dès qu'il s'y trouve
    func testEveryInjectedDeltaReachesTheScreenWithinBudget() throws {
        try XCTSkipIf(!isFakeServer(), "pas de faux serveur : /_hv/inject n'existe pas")
        let tokens = (0..<20).map { String(format: " d%02d", $0) }
        var delays: [Int] = []
        for run in 1...3 {
            post("/_hv/reset")
            for token in tokens { post("/_hv/inject", ["event": "message.delta", "delta": token]) }
            let app = launch()
            openBot(in: app)
            let input = element(.composerInput, in: app)
            input.click()
            // un delta toutes les 100 ms : le temps d'une lecture d'accessibilité reste petit devant l'écart entre deux deltas
            input.typeText("HV_PACE_100 delta")
            let started = Date()
            element(.composerSend, in: app).click()
            var seenAt: [String: Date] = [:]
            var lastText = ""
            let deadline = Date().addingTimeInterval(30)
            while seenAt.count < tokens.count, Date() < deadline {
                guard let text = lastMessageText(in: app) else { continue }
                let now = Date()
                lastText = text
                for token in tokens where seenAt[token] == nil && text.contains(token) { seenAt[token] = now }
            }
            if seenAt.count < tokens.count { print("HV-PERF09 debug tour \(run) : dernier texte lu = \(lastText.prefix(200))") }
            XCTAssertEqual(seenAt.count, tokens.count, "tour \(run) : tous les deltas ne sont pas à l'écran")
            let emitted = emissionTimes(since: started)
            // `message.delta` reste dans le journal sous son texte : chaque delta de ce tour y a une heure
            for token in tokens {
                guard let seen = seenAt[token], let time = emitted[token] else { XCTFail("tour \(run) : \(token) sans heure d'émission ou d'affichage"); continue }
                delays.append(max(0, milliseconds(seen.timeIntervalSince1970 - time)))
            }
            app.terminate()
        }
        let p95 = percentile(delays, 0.95)
        print("HV-PERF09 delta n=\(delays.count) p50_ms=\(percentile(delays, 0.5)) p95_ms=\(p95) max_ms=\(delays.max() ?? -1) budget_p95_ms=300")
        XCTAssertEqual(delays.count, 60)
        XCTAssertLessThanOrEqual(p95, 300)
    }

    /// Ce que le chien de garde de l'app a relevé : le nombre de réponses du fil principal et les blocages datés (secondes depuis 1970, durée en ms)
    private struct HangReport {
        let samples: Int
        let hangs: [(start: TimeInterval, milliseconds: Int)]

        /// Le plus long blocage qui recouvre la fenêtre, 0 quand aucun ne la touche
        func longest(from: TimeInterval, to: TimeInterval) -> Int {
            hangs.filter { $0.start <= to && $0.start + Double($0.milliseconds) / 1000 >= from }.map(\.milliseconds).max() ?? 0
        }
    }

    private func hangReport(in app: XCUIApplication) throws -> HangReport {
        let probe = element(.perfHang, in: app)
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "hd.perf.hang absent : l'app n'est pas un build Debug en mode test")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any], "rapport illisible : \(probe.label)")
        let samples = try XCTUnwrap(object["samples"] as? Int)
        let pairs = try XCTUnwrap(object["hangs"] as? [[Double]])
        return HangReport(samples: samples, hangs: pairs.map { ($0[0], Int($0[1])) })
    }

    /// Colle `text` dans le champ, envoie, attend la fin du tour, puis rend le plus long blocage du fil principal pendant ce temps
    /// La fenêtre commence avant le collage et finit après l'état du tour : elle recouvre ce que `typeKey` et `click` absorbent
    private func longestHang(pasting text: String, in app: XCUIApplication, run: Int) throws -> (hang: Int, report: HangReport) {
        let input = element(.composerInput, in: app)
        let send = element(.composerSend, in: app)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        input.click()
        let windowStart = Date().timeIntervalSince1970
        input.typeKey("v", modifierFlags: .command)
        let enabledBy = Date().addingTimeInterval(30)
        while !send.isEnabled, Date() < enabledBy { usleep(50_000) }
        XCTAssertTrue(send.isEnabled, "envoi \(run) : le collage n'a pas rempli le champ")
        send.click()
        XCTAssertTrue(element(.conversationState, in: app).waitForExistence(timeout: 30), "envoi \(run) : le tour ne finit pas")
        let windowEnd = Date().timeIntervalSince1970
        // le chien de garde date un blocage quand le fil principal répond de nouveau : il est relevé avant la lecture
        usleep(500_000)
        let report = try hangReport(in: app)
        return (report.longest(from: windowStart, to: windowEnd), report)
    }

    /// Cinq envois de 100 000 caractères : le plus long blocage du fil principal, daté par le chien de garde de l'app, pendant le collage et l'envoi
    func testSendingAHundredThousandCharactersNeverBlocksTheMainThreadForLong() throws {
        try XCTSkipIf(!isFakeServer(), "pas de faux serveur")
        let long = String(repeating: "é", count: 100_000)
        var hangs: [Int] = []
        for run in 1...5 {
            let app = launch()
            openBot(in: app)
            let (hang, report) = try longestHang(pasting: long, in: app, run: run)
            // un chien de garde mort lirait 0 : il doit avoir répondu de nombreuses fois
            XCTAssertGreaterThanOrEqual(report.samples, 100, "envoi \(run) : le chien de garde n'échantillonne pas")
            hangs.append(hang)
            print("HV-PERF09 long run=\(run) samples=\(report.samples) all_hangs_ms=\(report.hangs.map(\.milliseconds)) window_hang_ms=\(hang)")
            app.terminate()
        }
        print("HV-PERF09 long runs=\(hangs) max_hang_ms=\(hangs.max() ?? -1) budget_ms=250")
        XCTAssertLessThanOrEqual(hangs.max() ?? .max, 250)
    }

    /// Contrôle positif : l'app bloque son fil principal 400 ms au départ du tour (`HV_HANG_MS`), pendant le `click` qui attend lui-même le retour au repos
    /// Le chien de garde doit dater ce blocage, plus long que le budget de 250 ms : sans ce test, une sonde aveugle passerait pour une app fluide
    func testTheProbeSeesABlockLongerThanTheBudgetThatTheSynchronousCallsAbsorb() throws {
        try XCTSkipIf(!isFakeServer(), "pas de faux serveur")
        let app = launch(["HV_HANG_MS": "400"])
        openBot(in: app)
        let (hang, report) = try longestHang(pasting: "bloc", in: app, run: 1)
        print("HV-PERF09 control samples=\(report.samples) all_hangs_ms=\(report.hangs.map(\.milliseconds)) window_hang_ms=\(hang) injected_ms=400 budget_ms=250")
        XCTAssertGreaterThan(hang, 250, "la sonde ne voit pas un blocage de 400 ms : elle ne prouve rien")
        XCTAssertLessThan(hang, 700)
        app.terminate()
    }
}
