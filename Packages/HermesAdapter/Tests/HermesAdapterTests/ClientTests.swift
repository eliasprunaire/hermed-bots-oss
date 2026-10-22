import XCTest
@testable import HermesAdapter
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Remplace le réseau : enregistre chaque requête et répond par le corps que le test choisit
final class StubProtocol: URLProtocol {
    struct Seen {
        let method: String
        let path: String
        let query: String?
        let body: Data
        let authorization: String?
        let isCapabilityProbe: Bool
    }
    enum Reply {
        case http(Int, Data)
        case failure(URLError.Code)
    }

    static let lock = NSLock()
    static var seen: [Seen] = []
    static var respond: (Seen) -> Reply = { _ in .http(200, Data("{}".utf8)) }

    static func reset(_ respond: @escaping (Seen) -> Reply) {
        lock.lock(); defer { lock.unlock() }
        seen = []
        self.respond = respond
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {  // URLSession convertit httpBody en flux avant d'appeler le protocole
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer[0..<count])
            }
            stream.close()
        }
        let seen = Seen(method: request.httpMethod ?? "", path: request.url?.path ?? "", query: request.url?.query, body: body, authorization: request.value(forHTTPHeaderField: "Authorization"), isCapabilityProbe: request.value(forHTTPHeaderField: "X-Hermed-Capability-Probe") == "1")
        StubProtocol.lock.lock()
        StubProtocol.seen.append(seen)
        let reply = StubProtocol.respond(seen)
        StubProtocol.lock.unlock()
        switch reply {
        case .http(let status, let data):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }
}

final class ClientTests: XCTestCase {
    private let key = "cle-de-test-0123456789"

    private func client() -> HermesClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return HermesClient(baseURL: URL(string: "http://127.0.0.1:18642")!, apiKey: key, timeout: 5, configuration: configuration)
    }

    private func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func testTheSevenCallsSendTheContractRequests() async throws {
        let fixture = try Fixture.load(.current)
        StubProtocol.reset { seen in
            switch seen.path {
            case "/p/hv-bot-a/v1/models": return .http(200, try! fixture.response("profile_served"))
            case "/p/hv-bot-a/api/sessions": return .http(201, try! fixture.response("new_session"))
            case "/p/hv-bot-a/api/sessions/api_1_abc/model": return .http(200, try! fixture.response("set_model"))
            case "/p/hv-bot-a/api/sessions/api_1_abc/chat": return .http(200, try! fixture.response("send_message"))
            case "/p/hv-bot-a/v1/runs": return .http(202, try! fixture.response("start_run"))
            case "/p/hv-bot-a/v1/runs/run_1/events": return .http(200, try! fixture.sseStream())
            case "/p/hv-bot-a/v1/runs/run_1/approval": return .http(200, try! fixture.response("approve"))
            default: return .http(404, Data(#"{"error":"404: Not Found"}"#.utf8))
            }
        }
        let hermes = client()

        let profile = try await hermes.openProfile("hv-bot-a")
        let session = try await hermes.newSession(profile: "hv-bot-a")
        let lock = try await hermes.setModel(profile: "hv-bot-a", session: session.id, model: "hv-fake-2")
        let reply = try await hermes.send(profile: "hv-bot-a", session: session.id, text: "bonjour")
        let run = try await hermes.startRun(profile: "hv-bot-a", input: "HV_TOOL_DETACH go")
        let turn = try await hermes.readTurn(profile: "hv-bot-a", run: run)
        let request = try XCTUnwrap(turn.approvals.first)
        let result = try await hermes.approve(profile: "hv-bot-a", run: run, request: request, choice: "deny")

        XCTAssertEqual(profile.id, "hv-bot-a")
        XCTAssertEqual(lock.model, "hv-fake-2")
        XCTAssertEqual(reply.text, "HV-FAKE-REPLY model=hv-fake-2 user_msgs=1")
        XCTAssertEqual(turn.state, .completed)
        XCTAssertTrue(result.resolved)

        let seen = StubProtocol.seen
        XCTAssertEqual(seen.map { "\($0.method) \($0.path)" }, [
            "GET /p/hv-bot-a/v1/models",
            "POST /p/hv-bot-a/api/sessions",
            "POST /p/hv-bot-a/api/sessions/api_1_abc/model",
            "POST /p/hv-bot-a/api/sessions/api_1_abc/chat",
            "POST /p/hv-bot-a/v1/runs",
            "GET /p/hv-bot-a/v1/runs/run_1/events",
            "POST /p/hv-bot-a/v1/runs/run_1/approval",
        ])
        XCTAssertTrue(seen.allSatisfy { $0.authorization == "Bearer \(key)" })
        XCTAssertEqual(json(seen[2].body)["model"] as? String, "hv-fake-2")
        XCTAssertEqual(json(seen[3].body)["input"] as? String, "bonjour")
        XCTAssertEqual(json(seen[4].body)["input"] as? String, "HV_TOOL_DETACH go")
        XCTAssertEqual(json(seen[6].body)["request_id"] as? String, request.requestID)
        XCTAssertEqual(json(seen[6].body)["choice"] as? String, "deny")
        XCTAssertNil(json(seen[6].body)["execution_generation"])
    }

    func testApprovalCarriesTheExecutionGenerationWhenTheServerSentOne() async throws {
        StubProtocol.reset { _ in .http(200, Data(#"{"status":"resolved","prompt_id":"p1"}"#.utf8)) }
        let request = ApprovalRequest(requestID: "p1", executionGeneration: 1, command: "", description: "", choices: [])
        _ = try await client().approve(profile: "hv-bot-a", run: "run_1", request: request, choice: "once")
        let body = json(StubProtocol.seen[0].body)
        XCTAssertEqual(body["request_id"] as? String, "p1")
        XCTAssertEqual(body["execution_generation"] as? Int, 1)
    }

    private func realClient(_ server: RedirectServer) -> HermesClient {
        HermesClient(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, apiKey: key, timeout: 5)
    }

    // vrai serveur local : un URLProtocol de test ne passe pas par le délégué de redirection de FoundationNetworking (arrêt fatal sous Linux)
    func testARedirectOutsideTheOriginIsNotFollowed() async throws {
        for host in ["127.1", "localhost"] {
            let server = try RedirectServer { "http://\(host):\($0)/landed" }
            do {
                _ = try await realClient(server).openProfile("hv-bot-a")
                XCTFail("la redirection vers \(host) ne doit pas réussir")
            } catch HermesError.http(_, let status, _) {
                XCTAssertEqual(status, 302, host)
            }
            XCTAssertEqual(server.paths, ["/p/hv-bot-a/v1/models"], "aucune requête ne part vers \(host)")
        }
    }

    func testARedirectInsideTheSameProfileIsFollowed() async throws {
        let server = try RedirectServer { "http://127.0.0.1:\($0)/p/hv-bot-a/landed" }
        _ = try await realClient(server).openProfile("hv-bot-a")
        XCTAssertEqual(server.paths, ["/p/hv-bot-a/v1/models", "/p/hv-bot-a/landed"])
    }

    func testARedirectCannotChangeTheAuthenticatedProfile() async throws {
        for path in ["/p/ia/v1/models", "/landed", "/p/hv-bot-a-other/v1/models"] {
            let server = try RedirectServer { "http://127.0.0.1:\($0)\(path)" }
            do {
                _ = try await realClient(server).openProfile("hv-bot-a")
                XCTFail("La redirection change de profil")
            } catch HermesError.http(_, let status, _) { XCTAssertEqual(status, 302) }
            XCTAssertEqual(server.paths, ["/p/hv-bot-a/v1/models"])
        }
    }

    func testSameOrigin() {
        XCTAssertTrue(RedirectGuard.sameOrigin(URL(string: "http://LOCALHOST/old"), URL(string: "http://localhost:80/new")))
        XCTAssertFalse(RedirectGuard.sameOrigin(URL(string: "http://127.0.0.1:18642/old"), URL(string: "http://127.1:18642/new")))
        XCTAssertFalse(RedirectGuard.sameOrigin(URL(string: "http://127.0.0.1/old"), URL(string: "https://127.0.0.1/new")))
        XCTAssertFalse(RedirectGuard.sameOrigin(nil, URL(string: "http://127.0.0.1/new")))
    }

    func testAnEmptyMessageIsRefusedBeforeAnyRequest() async {
        StubProtocol.reset { _ in .http(200, Data("{}".utf8)) }
        do {
            _ = try await client().send(profile: "hv-bot-a", session: "api_1_abc", text: "")
            XCTFail("un message vide doit être refusé")
        } catch {
            XCTAssertEqual(error as? HermesError, .emptyMessage)
        }
        do {
            _ = try await client().startRun(profile: "hv-bot-a", input: "")
            XCTFail("un message vide doit être refusé")
        } catch {
            XCTAssertEqual(error as? HermesError, .emptyMessage)
        }
        XCTAssertEqual(StubProtocol.seen.count, 0)
    }

    func testALongMessageIsSentOnce() async throws {
        let fixture = try Fixture.load(.current)
        StubProtocol.reset { _ in .http(200, try! fixture.response("send_message")) }
        let text = String(repeating: "é", count: 100_000)
        _ = try await client().send(profile: "hv-bot-a", session: "api_1_abc", text: text)
        XCTAssertEqual(StubProtocol.seen.count, 1)
        XCTAssertEqual((json(StubProtocol.seen[0].body)["input"] as? String)?.count, 100_000)
    }

    func testAServerErrorIsReportedOnceWithItsStatusAndDetail() async {
        StubProtocol.reset { _ in .http(503, Data(#"{"error":"unavailable"}"#.utf8)) }
        do {
            _ = try await client().send(profile: "hv-bot-a", session: "api_1_abc", text: "bonjour")
            XCTFail("un 503 doit lever une erreur")
        } catch {
            XCTAssertEqual(error as? HermesError, .http(contract: "send_message", status: 503, detail: "unavailable"))
        }
        XCTAssertEqual(StubProtocol.seen.count, 1)
    }

    func testAHermesErrorBodyGivesItsMessage() async {
        let body = Data(#"{"error":{"message":"Missing field","type":"invalid_request_error","param":null,"code":null}}"#.utf8)
        StubProtocol.reset { _ in .http(400, body) }
        do {
            _ = try await client().newSession(profile: "hv-bot-a")
            XCTFail("un 400 doit lever une erreur")
        } catch {
            XCTAssertEqual(error as? HermesError, .http(contract: "new_session", status: 400, detail: "Missing field"))
        }
    }

    func testAnUnreachableServerIsNamedAsSuch() async {
        StubProtocol.reset { _ in .failure(.cannotConnectToHost) }
        do {
            _ = try await client().newSession(profile: "hv-bot-a")
            XCTFail("un serveur injoignable doit lever une erreur")
        } catch {
            guard case HermesError.unreachable(let url, _)? = error as? HermesError else { return XCTFail("\(error)") }
            XCTAssertEqual(url, "http://127.0.0.1:18642")
        }
    }

    func testAProfileThatIsNotServedGetsItsOwnError() async {
        StubProtocol.reset { _ in .http(404, Data(#"{"error": "Unknown or unconfigured profile"}"#.utf8)) }
        do {
            _ = try await client().openProfile("hv-old")
            XCTFail("un profil non servi doit lever une erreur")
        } catch {
            XCTAssertEqual(error as? HermesError, .profileNotServed("hv-old"))
        }
    }

    func testReadTurnReturnsAtTheStreamClosedMarker() async throws {
        let fixture = try Fixture.load(.previous)
        StubProtocol.reset { _ in .http(200, try! fixture.sseStream(extra: [["event": "run.failed", "error": "HTTP 400"]])) }
        let turn = try await client().readTurn(profile: "hv-bot-a", run: "run_1")
        XCTAssertEqual(turn.state, .failed)
        XCTAssertEqual(turn.error, "HTTP 400")
        XCTAssertEqual(turn.approvals.first?.executionGeneration, 1)
    }
}
