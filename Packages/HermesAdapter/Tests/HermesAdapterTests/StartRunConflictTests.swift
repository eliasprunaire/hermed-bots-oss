import XCTest
@testable import HermesAdapter

final class StartRunConflictTests: XCTestCase {
    func testA409BodyGivesTheConflictCodeNotABareStatus() {
        let denied = HermesError.http(contract: "start_run", status: 409, detail: "permission_denied")
        XCTAssertTrue(StartRunConflict.isForeignSession(denied))
        XCTAssertEqual(StartRunConflict.message(for: denied), StartRunConflict.foreignSession)

        let conflict = HermesError.http(contract: "start_run", status: 409, detail: "idempotency_key_conflict")
        XCTAssertFalse(StartRunConflict.isForeignSession(conflict))
        XCTAssertEqual(StartRunConflict.message(for: conflict), StartRunConflict.idempotency)

        let replay = HermesError.http(contract: "start_run", status: 409, detail: "idempotency_replay_unavailable")
        XCTAssertEqual(StartRunConflict.message(for: replay), StartRunConflict.idempotency)

        let bare = HermesError.http(contract: "start_run", status: 409, detail: nil)
        XCTAssertEqual(StartRunConflict.message(for: bare), StartRunConflict.generic)
        XCTAssertFalse(StartRunConflict.generic.contains("HTTP 409"))
        XCTAssertFalse(StartRunConflict.foreignSession.contains("HTTP 409"))
        XCTAssertFalse(StartRunConflict.idempotency.contains("HTTP 409"))
    }

    func testANon409IsNotAConflict() {
        let unauthorized = HermesError.http(contract: "start_run", status: 401, detail: "permission_denied")
        XCTAssertFalse(StartRunConflict.isForeignSession(unauthorized))
        XCTAssertNil(StartRunConflict.message(for: unauthorized))
        XCTAssertNil(StartRunConflict.message(for: HermesError.emptyMessage))
    }
}
