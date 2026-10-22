import XCTest
@testable import HermesAdapter

final class DecodingTests: XCTestCase {
    private func fixtures() throws -> [Fixture] { try FixtureVersion.allCases.map(Fixture.load) }

    /// Lit un flux SSE complet comme le fait le client
    private func readTurn(_ stream: Data, stopAtApproval: Bool = false) -> Turn {
        var parser = SSEParser()
        var reader = TurnReader(runID: "run_1", stopAtApproval: stopAtApproval)
        for frame in parser.feed(stream) { if reader.apply(frame) { break } }
        return reader.turn
    }

    // MARK: réponses JSON des deux versions de Hermes, avec et sans le mode fields

    func testNewSession() throws {
        for fixture in try fixtures() {
            for fields in [false, true] {
                let session = try Session.decode(fixture.response("new_session", fields: fields))
                XCTAssertEqual(session, Session(id: "api_1_abc", title: nil), "\(fixture.version) fields=\(fields)")
            }
        }
    }

    func testSendReply() throws {
        for fixture in try fixtures() {
            for fields in [false, true] {
                let reply = try Reply.decode(fixture.response("send_message", fields: fields), session: "api_1_abc")
                XCTAssertEqual(reply, Reply(sessionID: "api_1_abc", text: "HV-FAKE-REPLY model=hv-fake-2 user_msgs=1", model: "hv-fake-2"), "\(fixture.version) fields=\(fields)")
            }
        }
    }

    func testSetModel() throws {
        for fixture in try fixtures() {
            for fields in [false, true] {
                let lock = try ModelLock.decode(fixture.response("set_model", fields: fields), session: "api_1_abc", model: "hv-fake-2")
                XCTAssertEqual(lock, ModelLock(sessionID: "api_1_abc", model: "hv-fake-2"), "\(fixture.version) fields=\(fields)")
            }
        }
    }

    func testProfileServedHasNoDisplayNameAndFallsBackToTheId() throws {
        for fixture in try fixtures() {
            for fields in [false, true] {
                let profile = try Profile.decode(fixture.response("profile_served", fields: fields), requestedID: "hv-bot-a")
                XCTAssertEqual(profile, Profile(id: "hv-bot-a", displayName: "hv-bot-a"), "\(fixture.version) fields=\(fields)")
            }
        }
    }

    func testProfileDisplayNameWhenPresentAndDefaultWhenMissing() throws {
        let named = Data(#"{"data":[{"id":"hv-bot-a","display_name":"Bot A"}]}"#.utf8)
        let anonymous = Data(#"{"data":[{"id":"hv-bot-a"}]}"#.utf8)
        let empty = Data(#"{"object":"list","data":[]}"#.utf8)
        let wrongType = Data(#"{"data":[{"id":"hv-bot-a","display_name":42}]}"#.utf8)
        XCTAssertEqual(try Profile.decode(named, requestedID: "hv-bot-a").displayName, "Bot A")
        XCTAssertEqual(try Profile.decode(anonymous, requestedID: "hv-bot-a").displayName, "hv-bot-a")
        XCTAssertEqual(try Profile.decode(empty, requestedID: "hv-bot-a").displayName, "hv-bot-a")
        XCTAssertEqual(try Profile.decode(wrongType, requestedID: "hv-bot-a").displayName, "hv-bot-a")
    }

    func testMissingFieldsTakeTheirDefaultValue() throws {
        let reply = try Reply.decode(Data(#"{"object":"hermes.session.chat.completion"}"#.utf8), session: "s1")
        XCTAssertEqual(reply, Reply(sessionID: "s1", text: "", model: nil))
        let lock = try ModelLock.decode(Data("{}".utf8), session: "s1", model: "m1")
        XCTAssertEqual(lock, ModelLock(sessionID: "s1", model: "m1"))
    }

    func testAnIdentifierThatCannotBeInventedIsAnError() {
        XCTAssertThrowsError(try Session.decode(Data(#"{"session":{"title":"x"}}"#.utf8))) { error in
            guard case HermesError.decoding(let contract, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(contract, "new_session")
        }
        XCTAssertThrowsError(try Session.decode(Data("pas du json".utf8)))
        XCTAssertThrowsError(try Profile.decode(Data("[1]".utf8), requestedID: "x"))
    }

    // MARK: approbation, ids différents selon la version

    func testApprovalRequestAndResultInBothVersions() throws {
        let expected: [FixtureVersion: (id: String, generation: Int?)] = [
            .current: ("a0f9bf7c496b4be2abfd03cdf45873c1", nil),
            .previous: ("d3bf96d63eb34c9e8a445530b4dbce49", 1),
        ]
        for fixture in try fixtures() {
            guard case .approvalRequest(let request)? = try TurnEvent.decode(fixture.event(named: "approval.request")) else {
                return XCTFail("\(fixture.version): pas de demande d'approbation")
            }
            XCTAssertEqual(request.requestID, expected[fixture.version]?.id)
            XCTAssertEqual(request.executionGeneration, expected[fixture.version]?.generation)
            XCTAssertTrue(request.command.hasPrefix("python3"))
            let result = try ApprovalResult.decode(fixture.response("approve"), request: request, choice: "deny")
            XCTAssertEqual(result, ApprovalResult(requestID: request.requestID, choice: "deny", resolved: true), "\(fixture.version)")
        }
    }

    func testApprovalResultNotResolved() throws {
        let request = ApprovalRequest(requestID: "r1", executionGeneration: nil, command: "", description: "", choices: [])
        XCTAssertFalse(try ApprovalResult.decode(Data(#"{"resolved":0}"#.utf8), request: request, choice: "once").resolved)
        XCTAssertFalse(try ApprovalResult.decode(Data(#"{"status":"expired"}"#.utf8), request: request, choice: "once").resolved)
    }

    // MARK: flux d'événements

    func testSSEParserGivesTheSameFramesWhateverTheChunking() throws {
        let stream = try Fixture.load(.current).sseStream()
        var whole = SSEParser()
        let expected = whole.feed(stream)
        XCTAssertEqual(expected.last, .comment("stream closed"))
        var cut = SSEParser()
        var frames: [SSEFrame] = []
        var offset = stream.startIndex
        while offset < stream.endIndex {
            let end = min(offset + 7, stream.endIndex)
            frames += cut.feed(stream[offset..<end])
            offset = end
        }
        XCTAssertEqual(frames, expected)
        var crlf = SSEParser()
        XCTAssertEqual(crlf.feed(Data("data: {\"a\":1}\r\n\r\n".utf8)), [.data(Data(#"{"a":1}"#.utf8))])
    }

    func testTurnEndsCompletedWithAnUnknownEventInTheStream() throws {
        for fixture in try fixtures() {
            for fields in [false, true] {
                let turn = readTurn(try fixture.sseStream(fields: fields))
                XCTAssertEqual(turn.state, .completed, "\(fixture.version) fields=\(fields)")
                XCTAssertEqual(turn.text, "Réponse de test")
                XCTAssertEqual(turn.approvals.count, 1)
            }
        }
    }

    func testUnknownEventAndUndecodableDataAreIgnored() {
        XCTAssertEqual(TurnEvent.decode(Data(#"{"event":"hv.unknown_future_event","payload":{"x":1}}"#.utf8)), .other("hv.unknown_future_event"))
        XCTAssertEqual(TurnEvent.decode(Data(#"{"pas":"d'événement"}"#.utf8)), .other(""))
        XCTAssertNil(TurnEvent.decode(Data("pas du json".utf8)))
    }

    func testEveryTerminalStateIsReportedAsItIs() throws {
        let fixture = try Fixture.load(.current)
        let cases: [(event: [String: Any], state: TurnState, error: String?)] = [
            (["event": "run.failed", "error": "HTTP 400: hv fake provider failure"], .failed, "HTTP 400: hv fake provider failure"),
            (["event": "run.cancelled", "turn_exit_reason": "interrupted_by_user"], .cancelled, nil),
            (["event": "run.interrupted", "error": "The gateway restarted before this run settled."], .interrupted, "The gateway restarted before this run settled."),
            (["event": "run.completed", "status": "failed"], .failed, nil),
            (["event": "run.completed", "status": "etat-inconnu"], .completed, nil),
        ]
        for item in cases {
            // le faux serveur ajoute les événements injectés après la fin de la fixture : le dernier événement terminal gagne
            let turn = readTurn(try fixture.sseStream(extra: [item.event]))
            XCTAssertEqual(turn.state, item.state, "\(item.event)")
            XCTAssertEqual(turn.error, item.error, "\(item.event)")
        }
    }

    func testTurnStopsAtTheApprovalRequestWhenAsked() throws {
        let turn = readTurn(try Fixture.load(.previous).sseStream(), stopAtApproval: true)
        XCTAssertEqual(turn.state, .waitingForApproval)
        XCTAssertEqual(turn.approvals.map(\.requestID), ["d3bf96d63eb34c9e8a445530b4dbce49"])
    }

    // MARK: l'outil en cours (HD-11)

    private func stream(_ events: [[String: Any]]) throws -> Data {
        var text = ": open\n\n"
        for (index, event) in events.enumerated() {
            text += "id: \(index)\ndata: \(String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self))\n\n"
        }
        return Data(text.utf8)
    }

    func testToolStartedAndCompletedAreDecodedByTheirObservedNames() {
        XCTAssertEqual(TurnEvent.decode(Data(#"{"event":"tool.started","tool":"terminal","preview":"ls"}"#.utf8)), .toolStarted("terminal"))
        XCTAssertEqual(TurnEvent.decode(Data(#"{"event":"tool.completed","tool":"terminal","duration":0.1,"error":false}"#.utf8)), .toolFinished("terminal"))
        // sans nom d'outil, l'événement n'apprend rien : il reste inconnu
        XCTAssertEqual(TurnEvent.decode(Data(#"{"event":"tool.started","preview":"ls"}"#.utf8)), .other("tool.started"))
        XCTAssertEqual(TurnEvent.decode(Data(#"{"event":"tool.completed","tool":""}"#.utf8)), .other("tool.completed"))
    }

    func testTheCurrentToolIsTheOneStartedAndNotYetCompleted() throws {
        let started: [String: Any] = ["event": "tool.started", "tool": "shell.exec", "preview": "echo hv"]
        let completed: [String: Any] = ["event": "tool.completed", "tool": "shell.exec", "duration": 0.1, "error": false]
        XCTAssertNil(readTurn(try stream([])).tool)
        XCTAssertEqual(readTurn(try stream([started])).tool, "shell.exec")
        XCTAssertNil(readTurn(try stream([started, completed])).tool)
        // Hermes peut lancer deux outils à la fois : l'outil en cours est le dernier lancé qui tourne encore
        let other: [String: Any] = ["event": "tool.started", "tool": "file.write"]
        XCTAssertEqual(readTurn(try stream([started, other])).tool, "file.write")
        XCTAssertEqual(readTurn(try stream([started, other, ["event": "tool.completed", "tool": "file.write"]])).tool, "shell.exec")
        XCTAssertNil(readTurn(try stream([started, other, ["event": "tool.completed", "tool": "file.write"], completed])).tool)
        // une fin sans début ne change rien
        XCTAssertEqual(readTurn(try stream([started, ["event": "tool.completed", "tool": "inconnu"]])).tool, "shell.exec")
    }

    func testTheEndOfTheTurnClearsTheCurrentTool() throws {
        let turn = readTurn(try stream([["event": "tool.started", "tool": "shell.exec"], ["event": "run.failed", "error": "HTTP 400"]]))
        XCTAssertEqual(turn.state, .failed)
        XCTAssertNil(turn.tool)
    }

    func testAToolEventHandsOverTheTurnToTheCallback() async throws {
        let events: [[String: Any]] = [["event": "tool.started", "tool": "shell.exec"], ["event": "tool.completed", "tool": "shell.exec"], ["event": "run.completed", "output": "fin"]]
        let data = try stream(events)
        var parser = SSEParser()
        var reader = TurnReader(runID: "run_1")
        var seen: [String?] = []
        for frame in parser.feed(data) {
            let before = reader.changes
            _ = reader.apply(frame)
            if reader.changes != before { seen.append(reader.turn.tool) }
        }
        XCTAssertEqual(seen, ["shell.exec", nil, nil])
    }

    func testTheApprovalNamesTheToolThatAsksForIt() throws {
        let fixture = try Fixture.load(.current)
        // la fixture observée : `tool.started` (terminal) précède `approval.request`, qui ne porte pas le nom de l'outil
        let turn = readTurn(try fixture.sseStream(), stopAtApproval: true)
        XCTAssertEqual(turn.state, .waitingForApproval)
        XCTAssertEqual(turn.tool, "terminal")
        XCTAssertEqual(turn.approvals.map(\.tool), ["terminal"])
        // un nom donné par l'événement l'emporte sur l'outil en cours
        let own = readTurn(try stream([
            ["event": "tool.started", "tool": "shell.exec"],
            ["event": "approval.request", "request_id": "r1", "tool": "file.write", "command": "/tmp/hv.txt", "description": "écrire", "choices": ["once", "deny"]],
        ]))
        XCTAssertEqual(own.approvals.map(\.tool), ["file.write"])
        // sans outil en cours ni nom, le nom reste inconnu
        let none = readTurn(try stream([["event": "approval.request", "request_id": "r1", "command": "ls", "description": "", "choices": []]]))
        XCTAssertEqual(none.approvals.map(\.tool), [nil])
    }

    func testTurnWithoutTerminalEventKeepsItsLastNonTerminalState() throws {
        let fixture = try Fixture.load(.current)
        var parser = SSEParser()
        var reader = TurnReader(runID: "run_1")
        let head = String(decoding: try fixture.sseStream(), as: UTF8.self).components(separatedBy: "id: 3\n")[0]
        for frame in parser.feed(Data(head.utf8)) { _ = reader.apply(frame) }
        XCTAssertEqual(reader.turn.state, .waitingForApproval)
        let answered = String(decoding: try fixture.sseStream(), as: UTF8.self).components(separatedBy: "id: 4\n")[0]
        var other = SSEParser()
        var second = TurnReader(runID: "run_1")
        for frame in other.feed(Data(answered.utf8)) { _ = second.apply(frame) }
        XCTAssertEqual(second.turn.state, .running)
    }

    func testTurnTextFallsBackToTheTerminalOutput() throws {
        let stream = Data((#"data: {"event":"run.completed","output":"seul"}"# + "\n\n").utf8)
        XCTAssertEqual(readTurn(stream).text, "seul")
    }

    // MARK: liste des profils

    func testProfileTableKeepsActiveProfilesAndDropsStoppedOnes() throws {
        for fixture in try fixtures() {
            let ids = try ProfileTable.parse(fixture.profileTable).map(\.id)
            XCTAssertEqual(ids, ["default", "cyber", "gaming", "hv-bot-a", "hv-bot-b", "ia", "perso", "recherches", "sport", "tiny", "wikilibriste"])
            XCTAssertFalse(ids.contains("hv-old"))
        }
        XCTAssertEqual(try ProfileTable.parse("").count, 0)
    }
}
