import XCTest
@testable import HermesAdapter
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class CapabilitiesTests: XCTestCase {
    private let inert = "hd-probe-capabilities"
    private let profile = "hv-bot-a"

    // une route absente répond 404 en JSON sur le faux serveur et en texte brut sur Hermes (S8)
    private let absentBodies = [Data(#"{"error": "404: Not Found"}"#.utf8), Data("Unknown or unconfigured profile".utf8)]

    private func coded(_ code: String) -> Data {
        Data(#"{"error": {"message": "introuvable", "type": "invalid_request_error", "param": null, "code": "\#(code)"}}"#.utf8)
    }

    /// Répond comme Hermes à la requête inoffensive de chaque contrat ; `dropped` rend la route absente, `overrides` impose une réponse
    private func serve(
        _ version: FixtureVersion = .current,
        dropped: Set<Contract> = [],
        absent: Data? = nil,
        fields: Bool = false,
        overrides: [Contract: StubProtocol.Reply] = [:]
    ) throws {
        let fixture = try Fixture.load(version)
        let absent = absent ?? absentBodies[0]
        let variables = ["profile": profile, "session": inert, "run": inert]
        let sessionMissing = coded("session_not_found")
        let runMissing = coded("run_not_found")
        let badRequest = Data(#"{"error": {"message": "refusé", "type": "invalid_request_error", "param": null, "code": null}}"#.utf8)
        StubProtocol.reset { seen in
            guard let contract = Contract.allCases.first(where: { $0.method == seen.method && $0.resolve(variables) == seen.path }),
                  !dropped.contains(contract) else { return .http(404, absent) }
            if let reply = overrides[contract] { return reply }
            switch contract {
            case .version, .profileServed, .listSessions: return .http(200, try! fixture.response(contract.rawValue, fields: fields))
            case .newSession, .startRun: return .http(400, badRequest)
            case .sendMessage, .setModel, .sessionMessages: return .http(404, sessionMissing)
            case .runEvents, .approve: return .http(404, runMissing)
            }
        }
    }

    private func client() -> HermesClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return HermesClient(baseURL: URL(string: "http://127.0.0.1:18642")!, apiKey: "cle-de-test-0123456789", timeout: 5, configuration: configuration)
    }

    private func capabilities() async throws -> CapabilityMap {
        try await client().capabilities(profile: profile)
    }

    private func assertOnlyDisabled(_ expected: Set<Contract>, in map: CapabilityMap, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(map.entries.count, Contract.allCases.count - 1, file: file, line: line)
        for entry in map.entries {
            switch entry.state {
            case .available:
                XCTAssertFalse(expected.contains(entry.contract), "\(entry.contract) devrait être désactivé", file: file, line: line)
            case .disabled(let message):
                XCTAssertTrue(expected.contains(entry.contract), "\(entry.contract) ne devrait pas être désactivé : \(message)", file: file, line: line)
                XCTAssertFalse(message.isEmpty, file: file, line: line)
            }
        }
    }

    func testOnlyInertProbesAreMarkedForTheRequestLog() async throws {
        try serve()
        _ = try await capabilities()
        XCTAssertTrue(StubProtocol.seen.filter { $0.path != "/p/hv-bot-a/health" }.allSatisfy(\.isCapabilityProbe))
        StubProtocol.reset { _ in .http(200, Data(#"{"data":[]}"#.utf8)) }
        _ = try await client().messages(profile: profile, session: "session")
        XCTAssertEqual(StubProtocol.seen.count, 1)
        XCTAssertFalse(StubProtocol.seen[0].isCapabilityProbe)
    }

    // MARK: routes retirées

    func testEveryContractIsAvailableOnBothFixtureVersions() async throws {
        for version in FixtureVersion.allCases {
            try serve(version)
            let map = try await capabilities()
            XCTAssertEqual(map.version, try Fixture.load(version).root["version"] as? String)
            XCTAssertFalse(map.isDegraded, "\(version)")
            assertOnlyDisabled([], in: map)
        }
    }

    func testADroppedSetModelDisablesSetModelAlone() async throws {
        for absent in absentBodies {
            try serve(dropped: [.setModel], absent: absent)
            let map = try await capabilities()
            assertOnlyDisabled([.setModel], in: map)
            XCTAssertTrue(map.isDegraded)
            XCTAssertEqual(map[.setModel], .disabled(message: "Fonction désactivée (le changement de modèle) : Hermes ne propose plus cette route."))
        }
    }

    /// HD-10 : le sélecteur de modèle sonde `set_model` seul, une requête, pas les neuf contrats
    func testOneContractIsProbedAloneWithOneRequest() async throws {
        try serve()
        let available = try await client().capability(.setModel, profile: profile)
        XCTAssertEqual(available, .available)
        XCTAssertEqual(StubProtocol.seen.map { "\($0.method) \($0.path)" }, ["POST /p/hv-bot-a/api/sessions/\(inert)/model"])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: StubProtocol.seen[0].body) as? [String: String], ["model": ""])

        for absent in absentBodies {
            try serve(dropped: [.setModel], absent: absent)
            let disabled = try await client().capability(.setModel, profile: profile)
            XCTAssertEqual(disabled, .disabled(message: "Fonction désactivée (le changement de modèle) : Hermes ne propose plus cette route."))
            XCTAssertEqual(StubProtocol.seen.count, 1)
        }
    }

    func testAProbeOfOneContractStillFailsOnAnUnservedProfileAndOnAnOutage() async throws {
        try serve(overrides: [.setModel: .http(404, Data(#"{"error": "Unknown or unconfigured profile"}"#.utf8))])
        do {
            _ = try await client().capability(.setModel, profile: profile)
            XCTFail("un profil non servi doit lever une erreur")
        } catch {
            XCTAssertEqual(error as? HermesError, .profileNotServed(profile))
        }
        try serve(overrides: [.setModel: .http(503, Data())])
        do {
            _ = try await client().capability(.setModel, profile: profile)
            XCTFail("une panne doit lever une erreur, jamais désactiver la fonction")
        } catch {
            guard case HermesError.http(let contract, let status, _)? = error as? HermesError else { return XCTFail("\(error)") }
            XCTAssertEqual(contract, "set_model")
            XCTAssertEqual(status, 503)
        }
    }

    func testADroppedApproveDisablesApproveAlone() async throws {
        for absent in absentBodies {
            try serve(dropped: [.approve], absent: absent)
            let map = try await capabilities()
            assertOnlyDisabled([.approve], in: map)
            XCTAssertTrue(map.isDegraded)
        }
    }

    func testADroppedListSessionsDisablesListSessionsAlone() async throws {
        for absent in absentBodies {
            try serve(dropped: [.listSessions], absent: absent)
            let map = try await capabilities()
            assertOnlyDisabled([.listSessions], in: map)
            XCTAssertTrue(map.isDegraded)
        }
    }

    func testADroppedSessionMessagesDisablesTheTranscriptAlone() async throws {
        for absent in absentBodies {
            try serve(dropped: [.sessionMessages], absent: absent)
            let map = try await capabilities()
            assertOnlyDisabled([.sessionMessages], in: map)
            XCTAssertTrue(map.isDegraded)
            XCTAssertEqual(map[.sessionMessages], .disabled(message: "Fonction désactivée (la lecture d'un fil passé) : Hermes ne propose plus cette route."))
        }
    }

    func testADroppedProfileServedRouteIsNotTakenForAnUnservedProfile() async throws {
        try serve(dropped: [.profileServed], absent: absentBodies[1])
        assertOnlyDisabled([.profileServed], in: try await capabilities())
    }

    func testAChangedShapeDisablesThatContractAlone() async throws {
        try serve(overrides: [
            .listSessions: .http(200, Data(#"{"object": "list", "data": null}"#.utf8)),
            .profileServed: .http(200, Data("[]".utf8)),
            .approve: .http(405, Data()),
        ])
        let map = try await capabilities()
        assertOnlyDisabled([.listSessions, .profileServed, .approve], in: map)
        XCTAssertEqual(map[.approve], .disabled(message: "Fonction désactivée (la réponse à une approbation) : la réponse de Hermes a changé de forme (HTTP 405)."))
    }

    func testAProfileServedListWithoutDataDisablesThatContractAlone() async throws {
        for body in [#"{"object": "list", "data": null}"#, #"{"object": "list"}"#, #"{"object": "list", "data": {}}"#] {
            try serve(overrides: [.profileServed: .http(200, Data(body.utf8))])
            assertOnlyDisabled([.profileServed], in: try await capabilities())
        }
    }

    func testAnUnexpectedReplyDisablesThatContractAlone() async throws {
        // le 400 de list_sessions et les corps 2xx sans la forme attendue ne prouvent pas que la route existe
        let broken = Data(#"{"unexpected": "broken"}"#.utf8)
        try serve(overrides: [
            .listSessions: .http(400, broken),
            .startRun: .http(200, Data("{}".utf8)),
            .newSession: .http(200, Data("{}".utf8)),
            .sendMessage: .http(400, Data(#"{"error": {"message": "refusé", "code": null}}"#.utf8)),
            .setModel: .http(404, coded("run_not_found")),
            .approve: .http(404, coded("session_not_found")),
            .runEvents: .http(400, broken),
        ])
        let map = try await capabilities()
        assertOnlyDisabled([.listSessions, .startRun, .newSession, .sendMessage, .setModel, .approve, .runEvents], in: map)
        XCTAssertTrue(map.isDegraded)
    }

    func testAddedAndRemovedFieldsDisableNothing() async throws {
        try serve(fields: true)
        let map = try await capabilities()
        XCTAssertFalse(map.isDegraded)
        assertOnlyDisabled([], in: map)
    }

    // MARK: version

    func testAnUnknownVersionSetsDegradedModeAndStillConnects() async throws {
        try serve(overrides: [.version: .http(200, Data(#"{"status": "ok", "platform": "hermes-agent", "version": "9.9.9"}"#.utf8))])
        let hermes = client()
        let map = try await hermes.capabilities(profile: profile)
        XCTAssertEqual(map.version, "9.9.9")
        XCTAssertFalse(map.isVersionKnown)
        XCTAssertTrue(map.isDegraded)
        assertOnlyDisabled([], in: map)
        let opened = try await hermes.openProfile(profile)
        XCTAssertEqual(opened.id, profile)
    }

    func testAnUnreadableVersionSetsDegradedModeWithoutRefusing() async throws {
        let replies: [StubProtocol.Reply] = [
            .http(404, Data("404: Not Found".utf8)),
            .http(200, Data(#"{"status": "ok"}"#.utf8)),
            .http(200, Data(#"{"version": ""}"#.utf8)),
            .http(200, Data("ok".utf8)),
        ]
        for reply in replies {
            try serve(overrides: [.version: reply])
            let map = try await capabilities()
            XCTAssertNil(map.version)
            XCTAssertTrue(map.isDegraded)
            assertOnlyDisabled([], in: map)
        }
    }

    // La lecture de version ne sonde aucun autre contrat
    func testReadVersionAsksTheProfileHealthAlone() async throws {
        try serve()
        let version = try await client().readVersion(profile: profile)
        XCTAssertEqual(version, try Fixture.load(.current).root["version"] as? String)
        XCTAssertEqual(StubProtocol.seen.map(\.path), ["/p/hv-bot-a/health"])
    }

    func testReadVersionReturnsNilWhenHermesGivesNoVersionAndThrowsWhenUnreachable() async throws {
        try serve(overrides: [.version: .http(200, Data(#"{"status": "ok"}"#.utf8))])
        let none = try await client().readVersion(profile: profile)
        XCTAssertNil(none)
        try serve(overrides: [.version: .http(503, Data(#"{"error": "unavailable"}"#.utf8))])
        do {
            _ = try await client().readVersion(profile: profile)
            XCTFail("une API qui répond 503 est injoignable")
        } catch let error as HermesError {
            guard case .unreachable = error else { return XCTFail("\(error)") }
        }
    }

    func testKnownVersionsAreTheFixtureVersions() throws {
        let versions = try FixtureVersion.allCases.map { try XCTUnwrap(Fixture.load($0).root["version"] as? String) }
        XCTAssertEqual(CapabilityMap.knownVersions, Set(versions))
    }

    // MARK: erreurs de connexion

    func testAnUnreachableApiThrowsInsteadOfBuildingAMap() async throws {
        let replies: [StubProtocol.Reply] = [.http(503, Data(#"{"error": "unavailable"}"#.utf8)), .failure(.cannotConnectToHost)]
        for reply in replies {
            try serve(overrides: [.version: reply])
            do {
                _ = try await capabilities()
                XCTFail("une API injoignable ne donne pas de carte")
            } catch let error as HermesError {
                guard case .unreachable = error else { XCTFail("\(error)"); continue }
            }
            XCTAssertEqual(StubProtocol.seen.count, 1, "rien d'autre n'est sondé")
        }
    }

    func testAnUnservedProfileThrowsInsteadOfDisablingEverything() async throws {
        let unserved = StubProtocol.Reply.http(404, Data(#"{"error": "Unknown or unconfigured profile"}"#.utf8))
        try serve(overrides: Dictionary(uniqueKeysWithValues: Contract.features.map { ($0, unserved) }))
        do {
            _ = try await capabilities()
            XCTFail("un profil non servi ne donne pas de carte")
        } catch let error as HermesError {
            XCTAssertEqual(error, .profileNotServed(profile))
        }
        XCTAssertEqual(StubProtocol.seen.count, 2, "la version, puis profile_served")
    }

    func testARefusedKeyThrowsInsteadOfDisablingAContract() async throws {
        try serve(overrides: [.listSessions: .http(401, Data(#"{"error": {"message": "Invalid gateway API key", "code": "gateway_auth_failed"}}"#.utf8))])
        do {
            _ = try await capabilities()
            XCTFail("une clé refusée ne donne pas de carte")
        } catch let error as HermesError {
            XCTAssertEqual(error, .http(contract: "list_sessions", status: 401, detail: "Invalid gateway API key"))
        }
    }

    // MARK: effets de bord

    func testTheProbeSendsOneHarmlessRequestPerContract() async throws {
        try serve()
        _ = try await capabilities()
        XCTAssertEqual(StubProtocol.seen.map { "\($0.method) \($0.path)" }, [
            "GET /p/hv-bot-a/health",
            "GET /p/hv-bot-a/v1/models",
            "GET /p/hv-bot-a/api/sessions",
            "GET /p/hv-bot-a/api/sessions/\(inert)/messages",
            "POST /p/hv-bot-a/api/sessions",
            "POST /p/hv-bot-a/api/sessions/\(inert)/chat",
            "POST /p/hv-bot-a/v1/runs",
            "GET /p/hv-bot-a/v1/runs/\(inert)/events",
            "POST /p/hv-bot-a/api/sessions/\(inert)/model",
            "POST /p/hv-bot-a/v1/runs/\(inert)/approval",
        ])
        for seen in StubProtocol.seen where seen.method == "POST" && seen.path != "/p/hv-bot-a/api/sessions" {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: seen.body) as? [String: Any], seen.path)
            XCTAssertTrue((object["input"] as? String ?? "").isEmpty, "\(seen.path) ne démarre aucun tour")
        }
        let creation = try XCTUnwrap(StubProtocol.seen.first { $0.path == "/p/hv-bot-a/api/sessions" && $0.method == "POST" })
        XCTAssertNil(try? JSONSerialization.jsonObject(with: creation.body), "un corps JSON invalide : Hermes répond 400 et n'ouvre aucune session (S8)")
    }
}
