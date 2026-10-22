import XCTest

@MainActor
final class Compat: HD12Harness {
    func testRouteRemoved() {
        configure(mode: "drop-route")
        let app = launch()
        let feature = element("hd.banner.degraded.feature.set_model")
        XCTAssertTrue(feature.waitForExistence(timeout: 15))
        XCTAssertTrue(text(feature.identifier).contains("changement de modèle"))
        openBot()
        send()
        completed()
        HVShot.capture("hd12-degraded", app)
    }

    func testFieldsAddedRemoved() {
        configure(mode: "fields")
        launch()
        openBot()
        XCTAssertFalse(element("hd.loop.tokens").exists)
        send()
        completed()
        XCTAssertFalse(element("hd.loop.tokens").exists)
        XCTAssertFalse(element("hd.banner.error").exists)
    }

    func testRecentVersion() {
        configure(version: "0.22.1")
        let app = launch()
        XCTAssertTrue(element("hd.status.version").waitForExistence(timeout: 10))
        let deadline = Date().addingTimeInterval(15)
        while text("hd.status.version") != "0.22.1", Date() < deadline { usleep(100_000) }
        XCTAssertEqual(text("hd.status.version"), "0.22.1")
        openBot()
        send()
        completed()
        XCTAssertFalse(element("hd.banner.degraded").exists)
        HVShot.capture("hd12-previous", app)
    }

    func testApproveRemoved() {
        configure(mode: "drop-route", drop: "approve")
        let app = launch()
        XCTAssertTrue(element("hd.banner.degraded.feature.approve").waitForExistence(timeout: 15))
        XCTAssertTrue(element("hd.bots.row.hv-bot-a").exists)
        HVShot.capture("hd12-drop-approve", app)
    }

    func testNoTokens() {
        configure(omitTokens: true)
        let app = launch()
        openBot()
        send()
        completed()
        XCTAssertTrue(element("hd.loop.tokens").exists)
        XCTAssertTrue(text("hd.loop.tokens").contains("désactivé"))
        HVShot.capture("hd12-no-tokens", app)
    }

    func testUnknownVersion() {
        configure(version: "99.0.0")
        FakeServer.setProfileModels(["hv-bot-b": "model-y"])
        let app = launch()
        XCTAssertTrue(element("hd.banner.degraded").waitForExistence(timeout: 15))
        openBot()
        send()
        completed()
        let picker = element("hd.model.picker")
        picker.click()
        let option = element("hd.model.option.model-y")
        let foundOption = option.waitForExistence(timeout: 5)
        if !foundOption {
            let models = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "hd.model.")).allElementsBoundByIndex
            print("HV-MODELS \(models.map { "\($0.identifier) label=\($0.label) value=\(String(describing: $0.value))" })")
            print("HV-MODEL-TREE \(app.debugDescription)")
        }
        HVShot.capture("hd12-unknown-fake", app)
        XCTAssertTrue(foundOption)
        option.click()
        let confirmed = Date().addingTimeInterval(10)
        while text("hd.model.picker") != "model-y", Date() < confirmed { usleep(100_000) }
        XCTAssertEqual(text("hd.model.picker"), "model-y")
        for choice in ["yes", "no"] {
            send("HV_APPROVAL go")
            let answer = element("hd.approval." + choice)
            XCTAssertTrue(answer.waitForExistence(timeout: 10))
            answer.click()
            completed()
        }
        send("HV_TOOL_SHELL go")
        XCTAssertTrue(element("hd.tool.current").waitForExistence(timeout: 10))
        completed()
        XCTAssertTrue(element("hd.bots.row.hv-bot-b").exists)
        XCTAssertEqual(app.state, .runningForeground)
    }
}
