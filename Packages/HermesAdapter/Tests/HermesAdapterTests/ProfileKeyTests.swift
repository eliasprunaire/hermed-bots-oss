import XCTest
@testable import HermesAdapter
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ProfileKeyTests: XCTestCase {
    private func versionClient(keys: [String: String]) -> HermesClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return HermesClient(baseURL: URL(string: "http://hermes.invalid")!, apiKey: "default-test-key", configuration: configuration, apiKeyForProfile: { keys[$0] })
    }

    func testVersionReadsEachSelectedProfileWithItsOwnKey() async throws {
        let keys = ["hv-bot-a": "a-test-key", "hv-bot-b": "b-test-key"]
        StubProtocol.reset { request in
            let profile = request.path.contains("hv-bot-a") ? "hv-bot-a" : "hv-bot-b"
            guard request.path == "/p/\(profile)/health", request.authorization == "Bearer \(keys[profile]!)" else { return .http(401, Data()) }
            return .http(200, Data("{\"version\":\"\(profile)\"}".utf8))
        }
        let client = versionClient(keys: keys)
        for profile in ["hv-bot-a", "hv-bot-b", "hv-bot-a"] {
            let version = try await client.readVersion(profile: profile)
            XCTAssertEqual(version, profile)
        }
        XCTAssertEqual(StubProtocol.seen.map(\.path), ["/p/hv-bot-a/health", "/p/hv-bot-b/health", "/p/hv-bot-a/health"])
    }

    func testVersionWithoutAProfileKeySendsNoBearerAndPropagates401() async {
        StubProtocol.reset { request in
            XCTAssertNil(request.authorization)
            return .http(401, Data(#"{"error":"Invalid gateway API key"}"#.utf8))
        }
        do {
            _ = try await versionClient(keys: [:]).readVersion(profile: "hv-bot-a")
            XCTFail("Sans clé, Hermes doit répondre 401")
        } catch let error as HermesError {
            guard case .http(contract: "version", status: 401, detail: _) = error else { return XCTFail("Erreur inattendue") }
        } catch { XCTFail("Erreur inattendue") }
        XCTAssertEqual(StubProtocol.seen.map(\.path), ["/p/hv-bot-a/health"])
    }

    func testVersionPropagates401WithoutRetryOrFallback() async {
        StubProtocol.reset { _ in .http(401, Data(#"{"error":"Invalid gateway API key"}"#.utf8)) }
        do {
            _ = try await versionClient(keys: ["hv-bot-b": "refused-test-key"]).readVersion(profile: "hv-bot-b")
            XCTFail("La clé refusée doit produire une erreur")
        } catch let error as HermesError {
            guard case .http(contract: "version", status: 401, detail: _) = error else { return XCTFail("Erreur inattendue") }
        } catch { XCTFail("Erreur inattendue") }
        XCTAssertEqual(StubProtocol.seen.map(\.path), ["/p/hv-bot-b/health"])
    }

    func testEveryProfileRouteUsesItsOwnKey() throws {
        let keys = ["default": "default-test-key", "cyber": "cyber-test-key", "ia": "ia-test-key"]
        let client = HermesClient(baseURL: URL(string: "http://127.0.0.1:18642")!, apiKeyForProfile: { keys[$0] })
        for contract in Contract.allCases where contract.path.contains("{profile}") {
            for profile in keys.keys {
                let request = try client.makeRequest(contract, ["profile": profile, "run": "r", "session": "s"], body: nil)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(keys[profile]!)", contract.rawValue)
            }
        }
    }

    func testMissingProfileNeverUsesTheDefaultKey() throws {
        let client = HermesClient(baseURL: URL(string: "http://127.0.0.1:18642")!, apiKey: "default-test-key", apiKeyForProfile: { _ in nil })
        let request = try client.makeRequest(.listSessions, ["profile": "missing"], body: nil)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testUnreadableKeyStopsTheRequest() {
        let client = HermesClient(baseURL: URL(string: "http://127.0.0.1:18642")!, apiKeyForProfile: { _ in throw URLError(.userAuthenticationRequired) })
        XCTAssertThrowsError(try client.makeRequest(.listSessions, ["profile": "cyber"], body: nil))
    }
}
