import XCTest

/// Sonde de perf de HD-11 : dix approbations, de l'émission d'`approval.request` par le faux serveur à la feuille à l'écran, en mode `normal`
/// Deux horloges de la même machine : le faux serveur date l'émission dans son journal (`/_hv/sse/approval.request`), le runner date l'apparition de la feuille en la sondant toutes les 5 ms
/// Le délai mesuré contient donc la latence d'une requête d'accessibilité de XCUITest, qui s'ajoute à celui de l'app
/// Budget proposé par le plan : médiane de 500 ms au plus. Au trunk il n'y a pas de feuille : rien à chronométrer, le budget est absolu
@MainActor
final class ApprovalPerfProbe: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment

    override func setUp() {
        continueAfterFailure = false
    }

    /// L'heure à laquelle le faux serveur a écrit le premier `approval.request` après `after`, lue dans son journal
    private func emissionTime(after: Date) -> Date? {
        guard let base = environment["HV_API_URL"], let url = URL(string: base + "/_hv/log"), let data = try? Data(contentsOf: url),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return entries.compactMap { entry -> Date? in
            guard entry["m"] as? String == "SSE", entry["p"] as? String == "/_hv/sse/approval.request", let time = entry["t"] as? Double else { return nil }
            let date = Date(timeIntervalSince1970: time)
            return date >= after ? date : nil
        }.min()
    }

    private func median(_ values: [Int]) -> Int { values.sorted()[values.count / 2] }

    func testTenApprovalsFromTheRequestToTheSheetOnScreen() throws {
        let base = try XCTUnwrap(environment["HV_API_URL"], "HV_API_URL absent")
        try XCTSkipUnless(
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: XCTUnwrap(URL(string: base + "/_hv/ready")))) as? [String: Any])?["mode"] as? String == "normal",
            "le faux serveur n'est pas en mode normal"
        )
        FakeServer.reset()
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(fr)"]
        app.launchEnvironment["HV_TEST_MODE"] = "1"
        for name in ["HV_API_URL", "HV_TEST_API_KEY", "HV_TEST_API_KEYS"] {
            if let value = environment[name] { app.launchEnvironment[name] = value }
        }
        app.launch()

        func element(_ id: AccessibilityID) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", id.rawValue)).firstMatch
        }
        func shown(_ element: XCUIElement) -> String {
            if let value = element.value as? String, !value.isEmpty { return value }
            return element.label
        }

        let bot = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", AccessibilityID.botRow("hv-bot-a"))).firstMatch
        XCTAssertTrue(bot.waitForExistence(timeout: 20), "hd.bots.row.hv-bot-a absent")
        let hittable = Date().addingTimeInterval(10)
        while !bot.isHittable, Date() < hittable { usleep(50_000) }
        bot.click()
        let input = element(.composerInput)
        XCTAssertTrue(input.waitForExistence(timeout: 10), "hd.composer.input absent")

        var delays: [Int] = []
        for run in 1...10 {
            input.click()
            input.typeText("HV_APPROVAL go")
            let sentAt = Date()
            element(.composerSend).click()
            let sheet = element(.approvalSheet)
            // au trunk la feuille n'existe pas : un délai court suffit pour le constater, une feuille lente a 30 s
            let deadline = Date().addingTimeInterval(run == 1 ? 15 : 30)
            var seenAt: Date?
            while Date() < deadline {
                if sheet.exists { seenAt = Date(); break }
                usleep(5_000)
            }
            let seen = try XCTUnwrap(seenAt, "approbation \(run) : hd.approval.sheet absent (le trunk n'a pas de feuille d'approbation)")
            let emitted = try XCTUnwrap(emissionTime(after: sentAt), "approbation \(run) : le faux serveur n'a pas émis approval.request")
            let delay = Int(seen.timeIntervalSince(emitted) * 1000)
            delays.append(delay)
            print("HV-PERF11 approval run=\(run) request_to_sheet_ms=\(delay) send_to_request_ms=\(Int(emitted.timeIntervalSince(sentAt) * 1000))")
            XCTAssertEqual(shown(element(.approvalTool)), "file.write")
            element(.approvalYes).click()
            XCTAssertTrue(element(.conversationState).waitForExistence(timeout: 30), "approbation \(run) : le tour ne finit pas")
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "approbation \(run) : la feuille reste")
            // l'état terminal du tour précédent s'efface au tour suivant : on attend Envoyer libre
            let ready = Date().addingTimeInterval(10)
            while !element(.composerInput).isEnabled, Date() < ready { usleep(50_000) }
        }
        print("HV-PERF11 approval median_ms=\(median(delays)) runs=\(delays) budget_ms=500")
        XCTAssertEqual(delays.count, 10)
        XCTAssertLessThanOrEqual(median(delays), 500, "budget proposé par le plan : médiane de la demande à la feuille")
    }
}
