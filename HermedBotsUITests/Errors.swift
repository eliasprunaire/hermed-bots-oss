import XCTest

@MainActor
final class Errors: HD12Harness {
    func testApiUnreachable() {
        configure(mode: "down")
        let app = launch()
        XCTAssertTrue(element("hd.banner.error").waitForExistence(timeout: 9))
        XCTAssertTrue(element("hd.banner.error.retry").exists)
        HVShot.capture("hd12-down", app)
    }

    func testApiSlow() {
        configure(mode: "slow")
        let start = Date().timeIntervalSince1970
        let app = launch()
        XCTAssertTrue(element("hd.banner.waiting").waitForExistence(timeout: 4))
        HVShot.capture("hd12-slow", app)
        XCTAssertTrue(element("hd.banner.error").waitForExistence(timeout: 10))
        let health = request("/_hv/log").filter { ($0["p"] as? String)?.hasSuffix("/health") == true && ($0["t"] as? Double ?? 0) >= start }
        XCTAssertEqual(health.count, 1)
    }

    func testRefusedKey() {
        configure(rejectKey: true)
        let start = Date().timeIntervalSince1970
        let app = launch(wrongKey: true)
        XCTAssertTrue(element("hd.banner.error").waitForExistence(timeout: 10))
        XCTAssertTrue(text("hd.banner.error").localizedCaseInsensitiveContains("clé"))
        sleep(3)
        let attempts = request("/_hv/log").filter { ($0["s"] as? Int) == 401 && ($0["t"] as? Double ?? 0) >= start }
        XCTAssertEqual(attempts.count, 1)
        HVShot.capture("hd12-401", app)
    }

    func testRetry() {
        configure(mode: "down")
        let app = launch()
        XCTAssertTrue(element("hd.banner.error.retry").waitForExistence(timeout: 10))
        configure()
        click("hd.banner.error.retry")
        XCTAssertTrue(element("hd.banner.error").waitForNonExistence(timeout: 15))
        XCTAssertTrue(element("hd.bots.row.hv-bot-a").exists)
        HVShot.capture("hd12-retry", app)
    }

    func testLoopPause() {
        configure()
        let app = launch()
        openBot()
        send("HV_LOOP go")
        XCTAssertTrue(element("hd.banner.loop-pause").waitForExistence(timeout: 15))
        XCTAssertTrue(text("hd.banner.loop-pause").contains("répété"))
        XCTAssertFalse(element("hd.composer.send").isEnabled)
        XCTAssertTrue(element("hd.loop.notification").waitForExistence(timeout: 10))
        HVShot.capture("hd12-loop-pause", app)
        click("hd.loop.close")
        XCTAssertTrue(element("hd.banner.loop-pause").waitForNonExistence(timeout: 10))
        send("Bonjour après la pause")
        completed()
        XCTAssertFalse(request("/_hv/log").contains { ($0["p"] as? String)?.hasSuffix("/stop") == true })
        HVShot.capture("hd12-after-pause", app)
    }
}

@MainActor
final class NativeNotifications: HD12Harness {
    func testLoopPauseNotificationDelivery() throws {
        configure()
        let app = launch()
        openBot()
        send("HV_LOOP go")
        XCTAssertTrue(element("hd.banner.loop-pause").waitForExistence(timeout: 15))
        XCTAssertTrue(element("hd.loop.notification").waitForExistence(timeout: 10))
        let deadline = Date().addingTimeInterval(10)
        while text("hd.loop.notification").contains("en attente"), Date() < deadline { usleep(100_000) }
        let status = text("hd.loop.notification")
        print("HV-NOTIFICATION \(status)")
        HVShot.capture("hd12-notification-authorization", app)
        if status.contains("en attente") || status.contains("désactivée dans les réglages") {
            throw XCTSkip("Autorisation macOS absente dans la VM jetable : " + status)
        }
        XCTAssertTrue(status.contains("remise par macOS"))
    }
}

@MainActor
final class HD12Video: HD12Harness {
    func testRecordedRecovery() {
        configure(mode: "down")
        let app = launch()
        XCTAssertTrue(element("hd.banner.error.retry").waitForExistence(timeout: 10))
        let start = Date()
        var frame = 0
        func capture() {
            let name = String(format: "hd12-video-%03d", frame)
            let time = Date().timeIntervalSince1970
            HVShot.capture(name, app)
            print("HV-VIDEO frame=\(name) at=\(time)")
            frame += 1
        }
        capture()
        configure()
        click("hd.banner.error.retry")
        XCTAssertTrue(element("hd.banner.error").waitForNonExistence(timeout: 15))
        capture()
        openBot()
        capture()
        send("HV_LOOP go")
        XCTAssertTrue(element("hd.banner.loop-pause").waitForExistence(timeout: 15))
        capture()
        click("hd.loop.close")
        XCTAssertTrue(element("hd.banner.loop-pause").waitForNonExistence(timeout: 10))
        capture()
        send("Bonjour après la pause")
        completed()
        capture()
        while Date().timeIntervalSince(start) < 40 {
            usleep(500_000)
            capture()
        }
        XCTAssertTrue((30...60).contains(Date().timeIntervalSince(start)))
    }
}
