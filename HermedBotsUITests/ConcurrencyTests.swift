import XCTest

@MainActor
final class ConcurrencyTests: HD12Harness {
    override func setUpWithError() throws {
        try XCTSkipUnless(environment["HV_HD14_LANE"] == "1", "HD14 nécessite docs/spike/hd14-instruments/run-ui.sh dans la VM")
    }

    private let reason = "hd.bots.row.hv-bot-a.lock"
    private var baseline: Bool { environment["HV_HD14_BASELINE"] == "1" }

    override func launch(wrongKey: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(fr)"]
        app.launchEnvironment["HV_TEST_MODE"] = "1"
        app.launchEnvironment["HV_PROFILE_LOCKS"] = "1"
        for key in ["HV_API_URL", "HV_TEST_API_KEY", "HV_TEST_API_KEYS"] { app.launchEnvironment[key] = environment[key] }
        app.launch()
        self.app = app
        return app
    }

    private func type(_ text: String) {
        click("hd.composer.input")
        element("hd.composer.input").typeText(text)
    }

    private func hold(_ held: [String], drop: Bool = false) {
        request("/_hv/hold", body: ["held": held, "drop": drop])
    }

    private func waitBlocked() {
        XCTAssertTrue(element(reason).waitForExistence(timeout: 10))
        XCTAssertTrue(text(reason).contains("Hermes Desktop"))
        XCTAssertFalse(element("hd.composer.send").isEnabled)
    }

    private func assertNoWrites(since: Double) {
        let writes = request("/_hv/log").filter {
            ($0["t"] as? Double ?? 0) >= since && ($0["m"] as? String) == "POST" &&
            ($0["p"] as? String)?.hasPrefix("/p/hv-bot-a/") == true && ($0["probe"] as? Bool) != true
        }
        XCTAssertTrue(writes.isEmpty, "écritures après prise : \(writes.map { $0["p"] ?? "" })")
    }

    func test01HeldBeforeLaunch() {
        hold(["hv-bot-a"])
        let app = launch()
        openBot()
        if baseline {
            type("Bonjour trunk")
            XCTAssertTrue(element("hd.composer.send").isEnabled)
            click("hd.composer.send")
            completed()
            print("HD14 BASELINE trunk ouvre et écrit dans le profil tenu")
            HVShot.capture("hd14-trunk-held", app)
        } else {
            type("Message local")
            waitBlocked()
            assertNoWrites(since: 0)
            HVShot.capture("hd14-held", app)
        }
    }

    func test02TakenDuringUse() {
        let app = launch()
        openBot()
        send()
        completed()
        type("Ce message reste local")
        hold(["hv-bot-a"])
        if baseline {
            XCTAssertTrue(element("hd.composer.send").isEnabled)
        } else {
            waitBlocked()
            HVShot.capture("hd14-taken", app)
        }
    }

    func test03NoWriteAfterHold() {
        let app = launch()
        openBot()
        send()
        completed()
        hold(["hv-bot-a"])
        let heldAt = Date().timeIntervalSince1970
        waitBlocked()
        click("hd.composer.input")
        type("Ne pas envoyer\n")
        usleep(1_200_000)
        assertNoWrites(since: heldAt)
        HVShot.capture("hd14-no-write", app)
    }

    func test04OtherProfile() {
        hold(["hv-bot-a"])
        let app = launch()
        click("hd.bots.row.hv-bot-b")
        send()
        completed()
        XCTAssertTrue(element(reason).exists)
        HVShot.capture("hd14-other", app)
    }

    func test05Release() {
        hold(["hv-bot-a"])
        let app = launch()
        openBot()
        waitBlocked()
        hold([])
        XCTAssertTrue(element(reason).waitForNonExistence(timeout: 10))
        send("Après libération")
        completed()
        HVShot.capture("hd14-release", app)
    }

    func test06ApprovalTaken() {
        let app = launch()
        openBot()
        send("HV_APPROVAL go")
        XCTAssertTrue(element("hd.approval.sheet").waitForExistence(timeout: 20))
        hold(["hv-bot-a"])
        let heldAt = Date().timeIntervalSince1970
        XCTAssertTrue(element("hd.profile.lock").waitForExistence(timeout: 10))
        XCTAssertFalse(element("hd.approval.yes").isEnabled)
        XCTAssertFalse(element("hd.approval.no").isEnabled)
        usleep(1_200_000)
        assertNoWrites(since: heldAt)
        HVShot.capture("hd14-approval", app)
    }

    func test08DetectionDropped() {
        let app = launch()
        openBot()
        send()
        completed()
        hold([], drop: true)
        XCTAssertTrue(element("hd.banner.degraded.feature.profile_lock").waitForExistence(timeout: 10))
        type("État inconnu\n")
        XCTAssertFalse(element("hd.composer.send").isEnabled)
        let at = Date().timeIntervalSince1970
        usleep(1_200_000)
        assertNoWrites(since: at)
        HVShot.capture("hd14-drop", app)
    }

    func testPerfFiveHolds() { measureHolds(5) }
    func testPerfOneHold() { measureHolds(1) }

    private func measureHolds(_ count: Int) {
        var samples: [Double] = []
        let app = launch()
        openBot()
        type("Mesure")
        for _ in 0..<count {
            hold([])
            if !baseline { XCTAssertTrue(element(reason).waitForNonExistence(timeout: 10)) }
            let start = Date().timeIntervalSince1970
            hold(["hv-bot-a"])
            if baseline {
                XCTAssertTrue(element("hd.composer.send").isEnabled)
                click("hd.composer.send")
                completed()
                type("Mesure suivante")
                samples.append(-1)
            } else {
                let deadline = Date().addingTimeInterval(10)
                while !element(reason).exists && Date() < deadline { usleep(10_000) }
                XCTAssertTrue(element(reason).exists)
                XCTAssertFalse(element("hd.composer.send").isEnabled)
                samples.append((Date().timeIntervalSince1970 - start) * 1000)
            }
        }
        let median = samples.sorted()[count / 2]
        print("HV-PERF14 baseline=\(baseline) hold_to_disabled_ms=\(samples) median_ms=\(median) budget_ms=5000")
        if !baseline { XCTAssertLessThanOrEqual(median, 5000) }
    }

    func testRecordedReview() {
        hold(["hv-bot-a"])
        let app = launch()
        openBot()
        waitBlocked()
        let start = Date()
        var frame = 0
        func capture() {
            let name = String(format: "hd14-video-%03d", frame)
            let time = Date().timeIntervalSince1970
            HVShot.capture(name, app)
            print("HV-VIDEO frame=\(name) at=\(time)")
            frame += 1
        }
        capture()
        hold([])
        XCTAssertTrue(element(reason).waitForNonExistence(timeout: 10))
        capture()
        send("Profil libéré")
        completed()
        capture()
        hold(["hv-bot-a"])
        waitBlocked()
        capture()
        click("hd.bots.row.hv-bot-b")
        send("Autre profil disponible")
        completed()
        capture()
        while Date().timeIntervalSince(start) < 40 {
            usleep(500_000)
            capture()
        }
        XCTAssertTrue((30...60).contains(Date().timeIntervalSince(start)))
    }
}
