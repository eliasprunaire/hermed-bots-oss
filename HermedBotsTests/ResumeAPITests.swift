import HermesAdapter
import XCTest

final class ResumeAPITests: XCTestCase {
    func testAStartRunBodyKeepsAStableFingerprintWithoutANilModel() throws {
        let api = ResumeAPI(baseURL: URL(string: "http://hermes.invalid")!, apiKey: "k")
        let first = try api.makeRequest(profile: "default", input: "bonjour", session: "s1", model: nil, key: "idem")
        let second = try api.makeRequest(profile: "default", input: "bonjour", session: "s1", model: nil, key: "idem")
        XCTAssertEqual(first.httpBody, second.httpBody)
        XCTAssertEqual(first.value(forHTTPHeaderField: "Idempotency-Key"), "idem")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(first.httpBody)) as? [String: Any])
        XCTAssertEqual(json["input"] as? String, "bonjour")
        XCTAssertEqual(json["session_id"] as? String, "s1")
        XCTAssertNil(json["model"])
        XCTAssertEqual(json.count, 2)
    }

    func testA409BodyGivesTheConflictCodeNotABareStatus() {
        let denied = ResumeAPI.httpError(status: 409, body: Data(#"{"error":{"code":"permission_denied","message":"session owned by another surface"}}"#.utf8))
        XCTAssertEqual(denied, .http(contract: "start_run", status: 409, detail: "permission_denied"))
        XCTAssertEqual(StartRunConflict.message(for: denied), StartRunConflict.foreignSession)

        let conflict = ResumeAPI.httpError(status: 409, body: Data(#"{"error":"idempotency_key_conflict"}"#.utf8))
        XCTAssertEqual(StartRunConflict.message(for: conflict), StartRunConflict.idempotency)

        let bare = ResumeAPI.httpError(status: 409, body: Data())
        XCTAssertEqual(StartRunConflict.message(for: bare), StartRunConflict.generic)
        XCTAssertFalse(StartRunConflict.generic.contains("HTTP 409"))
        XCTAssertFalse(StartRunConflict.foreignSession.contains("HTTP 409"))
        XCTAssertFalse(StartRunConflict.idempotency.contains("HTTP 409"))
    }
}
