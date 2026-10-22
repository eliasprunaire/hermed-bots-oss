import XCTest
@testable import HermesAdapter

final class RoutesTests: XCTestCase {
    func testEveryContractMatchesTheTwoFixtures() throws {
        for version in FixtureVersion.allCases {
            let fixture = try Fixture.load(version)
            for contract in Contract.allCases {
                let entry = try XCTUnwrap(fixture.contracts[contract.rawValue], "\(contract.rawValue) absent de \(version)")
                XCTAssertEqual(contract.method, entry["method"] as? String, "\(contract.rawValue) \(version)")
                let path = entry["path"] as? String
                XCTAssertEqual(contract.path, contract == .version ? path.map { "/p/{profile}" + $0 } : path, "\(contract.rawValue) \(version)")
            }
        }
    }

    func testResolveEncodesEachVariableAsOneSegment() {
        XCTAssertEqual(
            Contract.sendMessage.resolve(["profile": "hv-bot-a", "session": "api 1/2"]),
            "/p/hv-bot-a/api/sessions/api%201%2F2/chat"
        )
    }
}
