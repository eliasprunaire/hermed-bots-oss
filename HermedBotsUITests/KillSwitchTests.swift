import XCTest

@MainActor
final class KillSwitchTests: HD12Harness {
    private let button = "hd.kill-switch.stop-all"
    private let status = "hd.kill-switch.status"
    private let profiles = ["hv-bot-a", "hv-bot-b", "cyber"]

    override func setUpWithError() throws {
        try XCTSkipUnless(environment["HV_HD15_LANE"] == "1", "HD15 nécessite le serveur de lane dans la VM")
    }

    override func launch(wrongKey: Bool = false) -> XCUIApplication {
        let app = super.launch(wrongKey: wrongKey)
        let first = element("hd.bots.row.default")
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        let deadline = Date().addingTimeInterval(20)
        while !first.isHittable, Date() < deadline { usleep(100_000) }
        XCTAssertTrue(first.isHittable, "la session Aqua de la VM ne laisse pas encore cliquer l'app")
        return app
    }

    private func revealBot(_ profile: String) {
        let row = element("hd.bots.row.\(profile)")
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        if !row.isHittable {
            let list = element("hd.bots.list")
            list.scroll(byDeltaX: 0, deltaY: 2000)
            for _ in 0..<12 {
                if row.isHittable { break }
                list.scroll(byDeltaX: 0, deltaY: -180)
            }
        }
        XCTAssertTrue(row.isHittable)
        row.click()
    }

    private func startThree() {
        for profile in profiles {
            revealBot(profile)
            send("HV_KILL go")
            XCTAssertTrue(element("hd.tool.current").waitForExistence(timeout: 15))
        }
    }

    private func openRun(_ profile: String) {
        let rows = request("/_hv/runs").filter { $0["profile"] as? String == profile }
        guard let session = rows.last?["session"] as? String else { return XCTFail("session absente") }
        revealBot(profile)
        let group = element("hd.bots.row.\(profile).threads")
        if !group.exists { click("hd.bots.row.\(profile)") }
        let row = group.descendants(matching: .any).matching(identifier: "hd.threads.row.\(session)").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
    }

    private func stops() -> [[String: Any]] {
        request("/_hv/log").filter { ($0["p"] as? String)?.hasSuffix("/stop") == true && ($0["probe"] as? Bool) != true }
    }

    private func caption() -> String {
        let item = element(status)
        guard item.exists else { return "" }
        return text(status)
    }

    private func cancelled() {
        let deadline = Date().addingTimeInterval(15)
        while request("/_hv/runs").contains(where: { $0["status"] as? String != "cancelled" }), Date() < deadline { usleep(50_000) }
        XCTAssertFalse(request("/_hv/runs").contains { $0["status"] as? String != "cancelled" })
        XCTAssertEqual(caption(), "")
    }

    func test01ThreeRunningTurns() {
        let app = launch()
        if environment["HV_HD15_BASELINE"] == "1" {
            openBot()
            XCTAssertFalse(element(button).exists)
            print("HD15 BASELINE trunk ne propose aucun bouton Tout arrêter")
            HVShot.capture("hd15-trunk-no-button", app)
            return
        }
        startThree()
        click(button)
        cancelled()
        XCTAssertEqual(stops().count, 3)
        for profile in profiles {
            openRun(profile)
            XCTAssertTrue(element("hd.conversation.state").waitForExistence(timeout: 10))
            XCTAssertTrue(text("hd.conversation.state").contains("annulé"))
        }
        XCTAssertEqual(request("/_hv/runs").filter { $0["status"] as? String == "cancelled" }.count, 3)
        HVShot.capture("hd15-stop-all", app)
    }

    func test03Idle() {
        let app = launch()
        openBot()
        XCTAssertEqual(caption(), "")
        click(button)
        XCTAssertEqual(caption(), "")
        XCTAssertEqual(stops().count, 0)
        HVShot.capture("hd15-idle", app)
    }

    func test04NoTunnel() {
        let app = launch()
        openBot()
        send("HV_KILL go")
        XCTAssertTrue(element("hd.tool.current").waitForExistence(timeout: 15))
        configure(mode: "down")
        let deadline = Date().addingTimeInterval(20)
        while element(button).isEnabled, Date() < deadline { usleep(50_000) }
        XCTAssertFalse(element(button).isEnabled)
        XCTAssertEqual(caption(), "")
        HVShot.capture("hd15-no-tunnel", app)
    }

    func test05DroppedCancel() {
        configure(mode: "drop-route", drop: "cancel_run")
        let app = launch()
        openBot()
        send("HV_KILL go")
        XCTAssertTrue(element("hd.tool.current").waitForExistence(timeout: 15))
        let deadline = Date().addingTimeInterval(15)
        while element(button).isEnabled, Date() < deadline { usleep(50_000) }
        XCTAssertFalse(element(button).isEnabled)
        XCTAssertEqual(caption(), "")
        XCTAssertEqual(stops().count, 0)
        HVShot.capture("hd15-drop", app)
    }

    func test06DoubleClick() {
        let app = launch()
        startThree()
        element(button).doubleClick()
        let deadline = Date().addingTimeInterval(15)
        while request("/_hv/runs").contains(where: { $0["status"] as? String != "cancelled" }), Date() < deadline { usleep(50_000) }
        XCTAssertFalse(request("/_hv/runs").contains { $0["status"] as? String != "cancelled" })
        XCTAssertEqual(stops().count, 3)
        HVShot.capture("hd15-double", app)
    }

    func test07KeptSessions() {
        let app = launch()
        startThree()
        click(button)
        cancelled()
        let rows = request("/_hv/sessions")
        XCTAssertEqual(rows.filter { ($0["messages"] as? Int ?? 0) > 0 && $0["http"] as? Int == 200 }.count, 3)
        for profile in profiles {
            openRun(profile)
            guard let id = rows.first(where: { $0["profile"] as? String == profile })?["ids"] as? [Int], let first = id.first else { return XCTFail("transcript absent") }
            let message = "hd.conversation.message.\(first)"
            XCTAssertTrue(element(message).waitForExistence(timeout: 10))
            XCTAssertTrue(text(message).contains("HV_KILL"))
        }
        XCTAssertFalse(request("/_hv/log").contains { $0["m"] as? String == "DELETE" })
        HVShot.capture("hd15-kept", app)
    }

    func test08WaitingApproval() {
        let app = launch()
        openBot()
        send("HV_KILL_APPROVAL go")
        XCTAssertTrue(element("hd.approval.sheet").waitForExistence(timeout: 15))
        click("hd.approval.stop-all")
        XCTAssertTrue(element("hd.approval.sheet").waitForNonExistence(timeout: 15))
        cancelled()
        XCTAssertTrue(text("hd.conversation.state").contains("annulé"))
        HVShot.capture("hd15-approval", app)
    }

    func testPerfFiveStops() {
        _ = launch()
        var samples: [Double] = []
        for _ in 0..<5 {
            startThree()
            let start = Date().timeIntervalSince1970
            click(button)
            cancelled()
            let rows = request("/_hv/runs").filter { ($0["cancelled_at"] as? Double ?? 0) >= start }
            XCTAssertEqual(rows.count, 3)
            samples.append(((rows.compactMap { $0["cancelled_at"] as? Double }.max() ?? start + 100) - start) * 1000)
        }
        print("HV-PERF15 click_to_server_cancelled_ms=\(samples) median_ms=\(samples.sorted()[2]) budget_ms=3000")
        XCTAssertLessThanOrEqual(samples.sorted()[2], 3000)
    }
}
