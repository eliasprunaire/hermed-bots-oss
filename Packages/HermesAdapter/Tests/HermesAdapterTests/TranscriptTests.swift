import XCTest
@testable import HermesAdapter
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HD-09 : le transcript d'un fil (`session_messages`), un tour lancé dans une session et suivi message après message
final class TranscriptTests: XCTestCase {
    private func client() -> HermesClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return HermesClient(baseURL: URL(string: "http://127.0.0.1:18642")!, apiKey: "cle-de-test-0123456789", timeout: 5, configuration: configuration)
    }

    private func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: décodage

    func testTheTranscriptOfBothVersionsKeepsTheUserAndAssistantTurnsWithTheirServerIndex() throws {
        for version in FixtureVersion.allCases {
            let fixture = try Fixture.load(version)
            for fields in [false, true] {
                let messages = try Message.decodeList(fixture.response("session_messages", fields: fields))
                // 0.22.1 ajoute une ligne `session_meta` sans texte : ce n'est pas un message
                XCTAssertEqual(messages, [
                    Message(id: 13, role: .user, text: "Bonjour"),
                    Message(id: 14, role: .assistant, text: "Réponse de test"),
                ], "\(version) fields=\(fields)")
            }
        }
    }

    func testOnlyAMessageWithAnIdentifierARoleAndATextIsShown() throws {
        let body = Data("""
        {"object":"list","data":[
          {"id":1,"role":"user","content":"gardé"},
          {"id":2,"role":"assistant","content":null},
          {"id":3,"role":"assistant","content":""},
          {"id":4,"role":"tool","content":"résultat d'outil"},
          {"id":5,"role":"system","content":"consigne"},
          {"role":"user","content":"sans identifiant"},
          {"id":"7","role":"user","content":"identifiant texte"},
          {"id":8,"role":"assistant","content":["pas","du","texte"]},
          {"id":9,"role":"assistant","content":"gardé aussi","zz_new_field":1},
          "pas un objet"
        ]}
        """.utf8)
        XCTAssertEqual(try Message.decodeList(body), [
            Message(id: 1, role: .user, text: "gardé"),
            Message(id: 9, role: .assistant, text: "gardé aussi"),
        ])
    }

    func testAnEmptyTranscriptIsAnEmptyList() throws {
        XCTAssertEqual(try Message.decodeList(Data(#"{"object":"list","session_id":"s","data":[]}"#.utf8)), [])
    }

    func testATranscriptWithoutADataListIsADecodingError() {
        for body in [#"{"object":"list"}"#, #"{"data":null}"#, #"{"data":{}}"#, "[]", "pas du json"] {
            XCTAssertThrowsError(try Message.decodeList(Data(body.utf8)), body) { error in
                guard case HermesError.decoding(let contract, _) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(contract, "session_messages")
            }
        }
    }

    // MARK: requêtes

    func testReadMessagesSendsOneGetOnTheContractRoute() async throws {
        let fixture = try Fixture.load(.current)
        StubProtocol.reset { _ in .http(200, try! fixture.response("session_messages")) }
        let messages = try await client().messages(profile: "hv-bot-a", session: "api_1_abc")
        XCTAssertEqual(messages.map(\.id), [13, 14])
        XCTAssertEqual(StubProtocol.seen.map { "\($0.method) \($0.path)" }, ["GET /p/hv-bot-a/api/sessions/api_1_abc/messages"])
        XCTAssertEqual(StubProtocol.seen.first?.authorization, "Bearer cle-de-test-0123456789")
    }

    func testAMissingSessionIsReportedWithTheContractName() async {
        StubProtocol.reset { _ in .http(404, Data(#"{"error":{"message":"Session not found: x","type":"invalid_request_error","param":null,"code":"session_not_found"}}"#.utf8)) }
        do {
            _ = try await client().messages(profile: "hv-bot-a", session: "x")
            XCTFail("une session absente doit lever une erreur")
        } catch {
            XCTAssertEqual(error as? HermesError, .http(contract: "session_messages", status: 404, detail: "Session not found: x"))
        }
    }

    func testStartRunCarriesTheSessionWhenOneIsGiven() async throws {
        let fixture = try Fixture.load(.current)
        StubProtocol.reset { _ in .http(202, try! fixture.response("start_run")) }
        _ = try await client().startRun(profile: "hv-bot-a", input: "bonjour", session: "api_1_abc")
        _ = try await client().startRun(profile: "hv-bot-a", input: "sans session")
        XCTAssertEqual(json(StubProtocol.seen[0].body)["session_id"] as? String, "api_1_abc")
        XCTAssertEqual(json(StubProtocol.seen[0].body)["input"] as? String, "bonjour")
        XCTAssertNil(json(StubProtocol.seen[1].body)["session_id"])
    }

    /// HD-10 : `POST /v1/runs` ignore le verrou de modèle de la session (S4, observé sur 0.22.2) : le modèle choisi part dans chaque run
    func testStartRunCarriesTheModelOnlyWhenOneIsGiven() async throws {
        let fixture = try Fixture.load(.current)
        StubProtocol.reset { _ in .http(202, try! fixture.response("start_run")) }
        _ = try await client().startRun(profile: "hv-bot-a", input: "avec", session: "api_1_abc", model: "hv-fake-2")
        _ = try await client().startRun(profile: "hv-bot-a", input: "sans", session: "api_1_abc")
        XCTAssertEqual(json(StubProtocol.seen[0].body)["model"] as? String, "hv-fake-2")
        XCTAssertEqual(json(StubProtocol.seen[0].body)["session_id"] as? String, "api_1_abc")
        XCTAssertNil(json(StubProtocol.seen[1].body)["model"])
    }

    func testALongMessageGoesOutInOneRun() async throws {
        let fixture = try Fixture.load(.current)
        StubProtocol.reset { _ in .http(202, try! fixture.response("start_run")) }
        _ = try await client().startRun(profile: "hv-bot-a", input: String(repeating: "é", count: 100_000), session: "api_1_abc")
        XCTAssertEqual(StubProtocol.seen.count, 1)
        XCTAssertEqual((json(StubProtocol.seen[0].body)["input"] as? String)?.count, 100_000)
    }

    // MARK: tour suivi en flux

    private func stream(_ events: [[String: Any]]) -> Data {
        var text = ": open\n\n"
        for (index, event) in events.enumerated() {
            let data = try! JSONSerialization.data(withJSONObject: event)
            text += "id: \(index)\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
        }
        return Data((text + ": stream closed\n\n").utf8)
    }

    private final class Updates: @unchecked Sendable {
        private let lock = NSLock()
        private var turns: [Turn] = []
        func add(_ turn: Turn) { lock.lock(); turns.append(turn); lock.unlock() }
        var all: [Turn] { lock.lock(); defer { lock.unlock() }; return turns }
    }

    func testReadTurnHandsOverTheTurnAfterEachChangeAndNotAfterAnUnknownEvent() async throws {
        StubProtocol.reset { _ in
            .http(200, self.stream([
                ["event": "message.delta", "delta": "Bon"],
                ["event": "hv.unknown_future_event", "payload": ["x": 1]],
                ["event": "message.delta", "delta": "jour"],
                ["event": "run.completed", "output": "Bonjour"],
            ]))
        }
        let updates = Updates()
        let turn = try await client().readTurn(profile: "hv-bot-a", run: "run_1") { updates.add($0) }
        XCTAssertEqual(updates.all.map(\.text), ["Bon", "Bonjour", "Bonjour"])
        XCTAssertEqual(updates.all.map(\.state), [.running, .running, .completed])
        XCTAssertEqual(turn, updates.all.last)
    }

    func testStoppingObservationDoesNotCancelTheRemoteRunOrConsumeLaterText() async throws {
        StubProtocol.reset { _ in .http(200, Data("data: {\"event\":\"tool.started\",\"tool\":\"terminal\"}\n\ndata: {\"event\":\"message.delta\",\"delta\":\"hidden\"}\n\n".utf8)) }
        let turn = try await client().readTurn(profile: "hv-bot-a", run: "run_1", onEvent: { _ in false })
        XCTAssertEqual(turn.text, "")
        XCTAssertEqual(turn.state, .running)
        XCTAssertEqual(StubProtocol.seen.count, 1)
        XCTAssertEqual(StubProtocol.seen.first?.method, "GET")
    }

    func testReadTurnWithoutACallbackBehavesAsBefore() async throws {
        StubProtocol.reset { _ in .http(200, self.stream([["event": "message.delta", "delta": "x"], ["event": "run.failed", "error": "HTTP 400"]])) }
        let turn = try await client().readTurn(profile: "hv-bot-a", run: "run_1")
        XCTAssertEqual(turn.state, .failed)
        XCTAssertEqual(turn.text, "x")
    }
}
