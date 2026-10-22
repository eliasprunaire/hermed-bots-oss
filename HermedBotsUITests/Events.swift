import XCTest

@MainActor
final class Events: HD12Harness {
    func testUnknownEventIgnored() {
        request("/_hv/inject", body: ["event": "hv.unknown_future_event", "payload": "future"])
        launch()
        openBot()
        send()
        completed()
        XCTAssertFalse(element("hd.banner.error").exists)
    }
}
