import XCTest
@testable import HermesAdapter
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HD-08 : la liste des profils (`list_profiles`) et celle des fils passés (`list_sessions`)
final class ListingTests: XCTestCase {
    private let key = "cle-de-test-0123456789"

    private func fixtures() throws -> [Fixture] { try FixtureVersion.allCases.map(Fixture.load) }

    private func client() -> HermesClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return HermesClient(baseURL: URL(string: "http://127.0.0.1:18642")!, apiKey: key, timeout: 5, configuration: configuration)
    }

    private let header = """

     Profile          Model                        Gateway      Alias        Distribution
     ───────────────    ───────────────────────────    ───────────    ───────────    ────────────────────

    """

    // MARK: table des profils

    func testTheTableGivesTheModelOfEachActiveProfile() throws {
        for fixture in try fixtures() {
            let profiles = try ProfileTable.parse(fixture.profileTable)
            XCTAssertEqual(profiles.first, Profile(id: "default", displayName: "default", model: "hv-fake-1"))
            XCTAssertEqual(Set(profiles.compactMap(\.model)), ["hv-fake-1"])
            XCTAssertFalse(profiles.contains { $0.id == "hv-old" })
        }
    }

    func testADashInTheModelColumnMeansNoModel() throws {
        let table = header + " ◆default         —                            running      —            —\n"
        XCTAssertEqual(try ProfileTable.parse(table), [Profile(id: "default", displayName: "default", model: nil)])
    }

    func testATableWithoutRowsIsAnEmptyListAndNotAnError() throws {
        XCTAssertEqual(try ProfileTable.parse(header), [])
        XCTAssertEqual(try ProfileTable.parse(""), [])
        XCTAssertEqual(try ProfileTable.parse("\n  \n"), [])
    }

    func testTextWithoutTheTableHeaderIsAnErrorAndNeverABot() {
        for text in ["bash: hermes: command not found\n", "Welcome to the host\nProfile list unavailable\n"] {
            XCTAssertThrowsError(try ProfileTable.parse(text)) { error in
                guard case HermesError.decoding(let contract, _)? = error as? HermesError else { return XCTFail("\(error)") }
                XCTAssertEqual(contract, "list_profiles")
            }
        }
    }

    func testLongEmojiAndRightToLeftNamesStayWhole() throws {
        let long = String(repeating: "x", count: 300)
        let names = [long, "🤖-bot-🚀", "مرحبا-بوت"]
        let table = header + names.map { "  \($0)   hv-fake-1                    running      —            —\n" }.joined()
        let profiles = try ProfileTable.parse(table)
        XCTAssertEqual(profiles.map(\.id), names)
        XCTAssertEqual(profiles.map(\.model), Array(repeating: "hv-fake-1", count: 3))
    }

    /// Hermes écrit les colonnes à largeur fixe : un nom ou un modèle plus long que sa colonne touche la suivante, un seul espace les sépare
    func testACellWiderThanItsColumnDoesNotHideTheGatewayState() throws {
        let longModel = "anthropic/claude-sonnet-4-5-20250929-thinking"
        let table = header
            + " ◆default         hv-fake-1                    running      —            —\n"
            + "  hv-wide-profile-001 hv-fake-1                    stopped      —            —\n"
            + "  hv-old          \(longModel) stopped      —            —\n"
            + "  hv-wide-profile-002 \(longModel) stopped      —            —\n"
            + "  ia              \(longModel) running      —            —\n"
            + "  hv-wide-profile-003 hv-fake-1                    running      —            —\n"
        XCTAssertEqual(try ProfileTable.parse(table), [
            Profile(id: "default", displayName: "default", model: "hv-fake-1"),
            Profile(id: "ia", displayName: "ia", model: longModel),
            Profile(id: "hv-wide-profile-003", displayName: "hv-wide-profile-003", model: "hv-fake-1"),
        ])
    }

    /// Une ligne écrite comme `_profile_list` de Hermes (hermes_cli/profile_cmd.py) : marqueur de 2 caractères, libellé rempli à 15, modèle coupé à 26 puis rempli à 28, état rempli à 12, le tout en points de code comme Python
    private func hermesRow(_ label: String, model: String = "hv-fake-1", state: String = "running", active: Bool = false) -> String {
        func pad(_ text: String, _ width: Int) -> String { text + String(repeating: " ", count: max(0, width - text.unicodeScalars.count)) }
        return (active ? " ◆" : "  ") + pad(label, 15) + " " + pad(String(String.UnicodeScalarView(model.unicodeScalars.prefix(26))), 28) + " " + pad(state, 12) + " " + pad("—", 12) + " —\n"
    }

    /// Hermes écrit `nom affiché (identifiant)` quand le profil a un nom affiché (hermes_cli/profiles.py, format_profile_label)
    func testADisplayNameGivesTheCanonicalIdAndKeepsTheNameForActiveAndStoppedProfiles() throws {
        let longModel = "anthropic/claude-sonnet-4-5-20250929-thinking"
        let table = header
            + hermesRow("default", active: true)
            + hermesRow("Cyber (cyber)")
            + hermesRow("Wiki libriste (wikilibriste)")
            + hermesRow("Mon bot (hv-old)", state: "stopped")
            + hermesRow("Bot (beta) (x)")
            + hermesRow("Mon bot running (ia)", model: longModel)
            + hermesRow("Ancien (hv-gone)", model: longModel, state: "stopped")
            + hermesRow("Moi (perso)", active: true)
        XCTAssertEqual(try ProfileTable.parse(table), [
            Profile(id: "default", displayName: "default", model: "hv-fake-1"),
            Profile(id: "cyber", displayName: "Cyber", model: "hv-fake-1"),
            Profile(id: "wikilibriste", displayName: "Wiki libriste", model: "hv-fake-1"),
            Profile(id: "x", displayName: "Bot (beta)", model: "hv-fake-1"),
            Profile(id: "ia", displayName: "Mon bot running", model: String(longModel.prefix(26))),
            Profile(id: "perso", displayName: "Moi", model: "hv-fake-1"),
        ])
    }

    /// Le modèle est lu dans sa propre colonne avant le libellé : un `(mot)` du modèle n'est jamais l'identifiant (vérificateur : `my (local) model` donnait `local`)
    func testAModelWithSpacesAndParenthesesNeverGivesTheId() throws {
        let model = "my (local) model"
        let ends26 = "claude-sonnet-large (beta)"
        XCTAssertEqual(ends26.count, 26)
        let table = header
            + hermesRow("cyber", model: model)
            + hermesRow("Cyber (cyber)", model: model)
            + hermesRow("Mon assistant perso (assistant)", model: model, active: true)
            + hermesRow("Équipe 👨‍👩‍👧 (equipe)", model: model)
            + hermesRow("ia", model: ends26)
            + hermesRow("Sport (beta) (sport)", model: ends26)
            + hermesRow("hv-old", model: model, state: "stopped")
            + hermesRow("Mon bot (hv-old)", model: model, state: "stopped")
        XCTAssertEqual(try ProfileTable.parse(table), [
            Profile(id: "cyber", displayName: "cyber", model: model),
            Profile(id: "cyber", displayName: "Cyber", model: model),
            Profile(id: "assistant", displayName: "Mon assistant perso", model: model),
            Profile(id: "equipe", displayName: "Équipe 👨‍👩‍👧", model: model),
            Profile(id: "ia", displayName: "ia", model: ends26),
            Profile(id: "sport", displayName: "Sport (beta)", model: ends26),
        ])
    }

    /// Hermes écrit des avertissements après la table (profile_channels.py, shared_credential_warning) : ce ne sont pas des bots
    func testALineThatIsNotAProfileRowIsNeverABot() throws {
        let warning = "⚠ Profile 'ia' shares its telegram credential with default: the bot can only belong to one profile. Give 'ia' its own bot (hermes -p ia setup, or the dashboard Messaging page) or remove the token from 'ia'; a multiplexed gateway parks the duplicate and `hermes gateway migrate --multiplex` refuses until it is gone."
        let table = header + hermesRow("default", active: true) + hermesRow("ia") + "\n" + warning + "\n\n"
        XCTAssertEqual(try ProfileTable.parse(table).map(\.id), ["default", "ia"])
    }

    // MARK: fils passés, décodage

    func testTheSessionListKeepsTheIdsAndTheTitlesWhenThereAreSome() throws {
        for fixture in try fixtures() {
            XCTAssertEqual(
                try Session.decodePage(fixture.response("list_sessions")).sessions,
                [Session(id: "s-past-1", title: "Fil passé 1"), Session(id: "s-open", title: "Fil courant")],
                "\(fixture.version)"
            )
            XCTAssertEqual(
                try Session.decodePage(fixture.response("list_sessions", fields: true)).sessions,
                [Session(id: "s-past-1", title: nil), Session(id: "s-open", title: nil)],
                "\(fixture.version) fields"
            )
        }
    }

    func testAnEmptyOrNullTitleIsNoTitleAndAnEntryWithoutIdIsSkipped() throws {
        let body = Data(#"{"data":[{"id":"a","title":""},{"id":"b","title":null},{"title":"sans id"},{"id":"","title":"vide"},{"id":"c","title":"Trois"}]}"#.utf8)
        let page = try Session.decodePage(body)
        XCTAssertEqual(page.sessions, [Session(id: "a", title: nil), Session(id: "b", title: nil), Session(id: "c", title: "Trois")])
        XCTAssertEqual(page.entries, 5)
        XCTAssertEqual(try Session.decodePage(Data(#"{"object":"list","data":[]}"#.utf8)).sessions, [])
    }

    /// HD-10 : le modèle d'un fil est celui que Hermes écrit dans l'entrée, tel quel ; absent, nul, vide ou d'un autre type vaut « aucun verrou »
    func testASessionEntryCarriesItsModelAsSent() throws {
        let body = Data(#"{"data":[{"id":"a","model":"hv-fake-2"},{"id":"b","model":null},{"id":"c","model":""},{"id":"d"},{"id":"e","model":"modèle inconnu (x) 9"},{"id":"f","model":7}]}"#.utf8)
        XCTAssertEqual(try Session.decodePage(body).sessions.map(\.model), ["hv-fake-2", nil, nil, nil, "modèle inconnu (x) 9", nil])
    }

    func testAListThatIsNotAListFailsToDecode() {
        for body in [#"{"data":null}"#, #"{"data":"x"}"#, "{}", "pas du json"] {
            XCTAssertThrowsError(try Session.decodePage(Data(body.utf8)), body) { error in
                guard case HermesError.decoding(let contract, _)? = error as? HermesError else { return XCTFail("\(error)") }
                XCTAssertEqual(contract, "list_sessions")
            }
        }
    }

    func testHasMoreIsReadAndAMissingOrNonBooleanHasMoreMeansNoMorePage() throws {
        XCTAssertTrue(try Session.decodePage(Data(#"{"data":[],"has_more":true}"#.utf8)).hasMore)
        XCTAssertFalse(try Session.decodePage(Data(#"{"data":[],"has_more":false}"#.utf8)).hasMore)
        XCTAssertFalse(try Session.decodePage(Data(#"{"data":[]}"#.utf8)).hasMore)
        XCTAssertFalse(try Session.decodePage(Data(#"{"data":[],"has_more":"oui"}"#.utf8)).hasMore)
    }

    // MARK: fils passés, client

    func testListSessionsSendsOneGetWithTheLimitAndTheKey() async throws {
        let fixture = try Fixture.load(.current)
        StubProtocol.reset { _ in .http(200, try! fixture.response("list_sessions")) }
        let list = try await client().listSessions(profile: "hv-bot-a")
        XCTAssertEqual(list, .sessions([Session(id: "s-past-1", title: "Fil passé 1"), Session(id: "s-open", title: "Fil courant")]))
        XCTAssertEqual(StubProtocol.seen.map { "\($0.method) \($0.path)" }, ["GET /p/hv-bot-a/api/sessions"])
        XCTAssertEqual(StubProtocol.seen.first?.query, "limit=200")
        XCTAssertEqual(StubProtocol.seen.first?.authorization, "Bearer \(key)")
    }

    func testADroppedRouteDisablesTheThreadsWithTheCapabilityMessage() async throws {
        for body in [#"{"error": "404: Not Found"}"#, "Unknown or unconfigured profile"] {
            StubProtocol.reset { _ in .http(404, Data(body.utf8)) }
            let list = try await client().listSessions(profile: "hv-bot-a")
            XCTAssertEqual(list, .disabled(message: "Fonction désactivée (la liste des fils passés) : Hermes ne propose plus cette route."), body)
        }
    }

    func testAChangedShapeDisablesTheThreadsToo() async throws {
        StubProtocol.reset { _ in .http(200, Data(#"{"object": "list", "data": null}"#.utf8)) }
        let list = try await client().listSessions(profile: "hv-bot-a")
        XCTAssertEqual(list, .disabled(message: "Fonction désactivée (la liste des fils passés) : la réponse de Hermes a changé de forme (HTTP 200)."))
    }

    func testAProfileThatIsNotServedAndABadKeyAreErrorsNotAMissingFeature() async {
        StubProtocol.reset { _ in .http(404, Data(#"{"error": "Unknown or unconfigured profile"}"#.utf8)) }
        do {
            _ = try await client().listSessions(profile: "hv-old")
            XCTFail("un profil non servi doit lever une erreur")
        } catch {
            XCTAssertEqual(error as? HermesError, .profileNotServed("hv-old"))
        }
        StubProtocol.reset { _ in .http(401, Data(#"{"error": {"message": "Invalid gateway API key", "code": "gateway_auth_failed"}}"#.utf8)) }
        do {
            _ = try await client().listSessions(profile: "hv-bot-a")
            XCTFail("une clé refusée doit lever une erreur")
        } catch {
            XCTAssertEqual(error as? HermesError, .http(contract: "list_sessions", status: 401, detail: "Invalid gateway API key"))
        }
    }

    func testAnUnreachableServerIsAnErrorNotAMissingFeature() async {
        StubProtocol.reset { _ in .failure(.cannotConnectToHost) }
        do {
            _ = try await client().listSessions(profile: "hv-bot-a")
            XCTFail("un serveur injoignable doit lever une erreur")
        } catch {
            guard case HermesError.unreachable? = error as? HermesError else { return XCTFail("\(error)") }
        }
    }

    // MARK: fils passés, pagination par has_more et offset

    /// Faux Hermes à `total` fils : plafonne `limit` à 200 comme le vrai (observé sur hv-hermes-test) et pose `has_more`
    private func serveSessions(total: Int, skipping: Set<Int> = []) {
        StubProtocol.reset { seen in
            let items = URLComponents(string: "http://x/?\(seen.query ?? "")")?.queryItems ?? []
            let limit = min(Int(items.first { $0.name == "limit" }?.value ?? "") ?? 50, 200)
            let offset = Int(items.first { $0.name == "offset" }?.value ?? "") ?? 0
            let slice = Array(offset..<min(offset + limit, total))
            let data: [[String: Any]] = slice.map { skipping.contains($0) ? ["title": "sans id"] : ["id": "s\($0)", "title": "Fil \($0)"] }
            let body: [String: Any] = ["object": "list", "data": data, "limit": limit, "offset": offset, "has_more": offset + limit < total]
            return .http(200, try! JSONSerialization.data(withJSONObject: body))
        }
    }

    func testMoreThanOnePageOfThreadsIsReadInFullWithTheOffsetOfTheNextPage() async throws {
        serveSessions(total: 201)
        guard case .sessions(let sessions) = try await client().listSessions(profile: "hv-bot-a") else { return XCTFail("fils attendus") }
        XCTAssertEqual(sessions.count, 201)
        XCTAssertEqual(sessions.first, Session(id: "s0", title: "Fil 0"))
        XCTAssertEqual(sessions.last, Session(id: "s200", title: "Fil 200"))
        XCTAssertEqual(Set(sessions.map(\.id)).count, 201)
        XCTAssertEqual(StubProtocol.seen.map(\.query), ["limit=200", "limit=200&offset=200"])
        XCTAssertEqual(Set(StubProtocol.seen.map(\.authorization)), ["Bearer \(key)"])
    }

    func testExactlyOnePageOfThreadsAsksForNoSecondPage() async throws {
        serveSessions(total: 200)
        guard case .sessions(let sessions) = try await client().listSessions(profile: "hv-bot-a") else { return XCTFail("fils attendus") }
        XCTAssertEqual(sessions.count, 200)
        XCTAssertEqual(StubProtocol.seen.map(\.query), ["limit=200"])
    }

    func testTheNextOffsetCountsTheEntriesOfTheServerAndNotOnlyTheOnesWithAnId() async throws {
        serveSessions(total: 450, skipping: [5, 199])
        guard case .sessions(let sessions) = try await client().listSessions(profile: "hv-bot-a") else { return XCTFail("fils attendus") }
        XCTAssertEqual(sessions.count, 448)
        XCTAssertEqual(Set(sessions.map(\.id)).count, 448)
        XCTAssertEqual(StubProtocol.seen.map(\.query), ["limit=200", "limit=200&offset=200", "limit=200&offset=400"])
    }

    func testAServerThatNeverStopsSayingHasMoreIsCutAtTheLastPage() async throws {
        let page = try JSONSerialization.data(withJSONObject: ["data": [["id": "s1"]], "has_more": true])
        StubProtocol.reset { _ in .http(200, page) }
        _ = try await client().listSessions(profile: "hv-bot-a")
        XCTAssertEqual(StubProtocol.seen.count, HermesClient.maxSessionPages)
        let empty = try JSONSerialization.data(withJSONObject: ["data": [], "has_more": true])
        StubProtocol.reset { _ in .http(200, empty) }
        _ = try await client().listSessions(profile: "hv-bot-a")
        XCTAssertEqual(StubProtocol.seen.count, 1)
    }

    func testAFailureOnALaterPageIsAnErrorAndNeverAShortenedList() async {
        StubProtocol.reset { seen in
            guard seen.query?.contains("offset=") == true else {
                return .http(200, try! JSONSerialization.data(withJSONObject: ["data": [["id": "s1"]], "has_more": true]))
            }
            return .http(502, Data(#"{"error": "bad gateway"}"#.utf8))
        }
        do {
            _ = try await client().listSessions(profile: "hv-bot-a")
            XCTFail("une page en échec doit lever une erreur")
        } catch {
            XCTAssertEqual(error as? HermesError, .http(contract: "list_sessions", status: 502, detail: "bad gateway"))
        }
    }
}
