import LoopGuard
import HermesAdapter
import XCTest

// compilé dans le paquet de tests lui-même, sans l'app comme hôte : un faux Hermes (URLProtocol) garde chaque requête jusqu'à ce que le test y réponde, aucun réseau
@MainActor
final class ConversationModelTests: XCTestCase {
    private let bot = "hv-bot"
    private let emptyTranscript = #"{"data":[]}"#

    /// Le flux d'un tour qui répond `text` et finit completed, avec le marqueur de fin de flux
    private func completedTurn(_ text: String) -> String {
        "data: {\"event\":\"message.delta\",\"delta\":\"\(text)\"}\n\ndata: {\"event\":\"run.completed\",\"output\":\"\(text)\"}\n\n: stream closed\n\n"
    }

    /// Le flux d'un tour qui finit failed avec l'erreur de Hermes (`run.failed`)
    private func failedTurn(_ error: String) -> String {
        "data: {\"event\":\"run.failed\",\"error\":\"\(error)\"}\n\n: stream closed\n\n"
    }

    /// `reachable: false` : aucun client, comme quand le tunnel n'est pas ouvert
    /// `bots`, `listedThread` et `startedReads` sont ce que la barre latérale sait : les profils actifs, ce que la liste des fils dit d'un fil (son modèle, le numéro de la lecture), et le numéro de la dernière lecture partie
    /// `approvalRetry` est l'attente entre deux essais d'une décision qui ne part pas
    private func makeModel(reachable: Bool = true, bots: @escaping @MainActor () -> [Bot] = { [] }, listedThread: @escaping @MainActor (String, String) -> (model: String?, read: Int)? = { _, _ in nil }, startedReads: @escaping @MainActor () -> Int = { 0 }, approvalRetry: Duration = .milliseconds(20), resumeStore: ResumeStore? = nil, onAPIError: @escaping @MainActor (Error, String) -> Void = { _, _ in }) -> ConversationModel {
        GateProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GateProtocol.self]
        // hôte factice en `.invalid` (RFC 6761) : il ne se résout jamais, GateProtocol répond à sa place
        let client = HermesClient(baseURL: URL(string: "http://hermes.invalid")!, configuration: configuration)
        return ConversationModel(client: { reachable ? client : nil }, bots: bots, listedThread: listedThread, startedReads: startedReads, approvalRetry: approvalRetry, resumeStore: resumeStore, onAPIError: onAPIError)
    }

    /// L'état d'un fil du bot de test, qu'il soit à l'écran ou non
    private func thread(_ session: String, in model: ConversationModel) -> ConversationMachine.ThreadState? {
        model.machine.threads[ConversationMachine.Key(bot: bot, thread: .session(session))]
    }

    private func eventually(_ what: String, timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition jamais vraie : \(what)")
    }

    /// La n-ième requête reçue par le faux Hermes, après avoir vérifié sa méthode et la fin de son chemin
    private func held(_ index: Int, _ method: String, _ pathEnd: String) async throws -> GateProtocol {
        await eventually("la requête \(index) (\(method) …\(pathEnd))") { GateProtocol.requests.count > index }
        let all = GateProtocol.requests
        let found = try XCTUnwrap(all.indices.contains(index) ? all[index] : nil, "requête \(index) absente")
        XCTAssertEqual(found.request.httpMethod, method, "requête \(index)")
        XCTAssertTrue(found.request.url?.path.hasSuffix(pathEnd) == true, "requête \(index) : \(found.request.url?.path ?? "?") ne finit pas par \(pathEnd)")
        return found
    }

    private func transcript(_ lines: (Int, String, String)...) -> String {
        let rows = lines.map { #"{"id":\#($0.0),"role":"\#($0.1)","content":"\#($0.2)"}"# }
        return #"{"data":[\#(rows.joined(separator: ","))]}"#
    }

    /// La première requête reçue qui a cette méthode et ce chemin, quel que soit son rang
    private func heldRequest(_ method: String, _ pathEnd: String) async throws -> GateProtocol {
        func match(_ found: GateProtocol) -> Bool {
            found.request.httpMethod == method && found.request.url?.path.hasSuffix(pathEnd) == true
        }
        await eventually("une requête \(method) …\(pathEnd)") { GateProtocol.requests.contains(where: match) }
        return try XCTUnwrap(GateProtocol.requests.first(where: match), "requête \(method) …\(pathEnd) absente")
    }

    /// Ouvre un fil vide : le modèle a un bot, un fil et rien à lire
    private func openEmptyThread(_ model: ConversationModel, session: String) async throws {
        model.open(session: session, of: bot)
        try await held(0, "GET", "/api/sessions/\(session)/messages").reply(emptyTranscript)
        await eventually("transcript lu") { !model.isLoading }
    }

    func testDefinitiveReplayFailuresRemoveTheSavedRunAndDoNotRestoreItAgain() async throws {
        for (status, body) in [(404, #"{"error":{"code":"run_not_found","message":"gone"}}"#),
                               (200, "data: {\"event\":\"replay.truncated\"}\n\n")] {
            let store = ResumeStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            let model = makeModel(resumeStore: store)
            try await openEmptyThread(model, session: "t")
            model.draft = "go"
            model.send()
            try await held(1, "POST", "/v1/runs").reply(#"{"run_id":"r1"}"#)
            let events = try await held(2, "GET", "/v1/runs/r1/events")
            XCTAssertEqual(try store.records(connection: "http://hermes.invalid", bot: bot).count, 1)
            events.reply(body, status: status)
            await eventually("échec définitif") { model.conversation.failure != nil }
            XCTAssertTrue(try store.records(connection: "http://hermes.invalid", bot: bot).isEmpty)
            let relaunched = makeModel(resumeStore: store)
            relaunched.select(bot: bot)
            try? await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(GateProtocol.requests.isEmpty, "aucune restauration du tour abandonné")
        }
    }

    func testRepeatedClosedStreamsWithoutProgressStopWithoutAnotherSendOrRestore() async throws {
        let store = ResumeStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let model = makeModel(resumeStore: store)
        try await openEmptyThread(model, session: "t")
        model.draft = "go"
        model.send()
        try await held(1, "POST", "/v1/runs").reply(#"{"run_id":"r1"}"#)
        for index in 2...4 {
            try await held(index, "GET", "/v1/runs/r1/events").reply(": stream closed\n\n")
        }
        await eventually("reprise bornée") { model.conversation.failure != nil }
        XCTAssertTrue(try store.records(connection: "http://hermes.invalid", bot: bot).isEmpty)
        let requests = GateProtocol.requests.count
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(GateProtocol.requests.count, requests)
        XCTAssertEqual(GateProtocol.requests.filter { $0.request.httpMethod == "POST" }.count, 1)
    }

    func testReplayProgressResetsTheClosedStreamLimitAndLinkFailuresKeepTheRun() async throws {
        let store = ResumeStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let model = makeModel(resumeStore: store)
        try await openEmptyThread(model, session: "t")
        model.draft = "go"
        model.send()
        try await held(1, "POST", "/v1/runs").reply(#"{"run_id":"r1"}"#)
        for index in 2...5 {
            try await held(index, "GET", "/v1/runs/r1/events").reply("", status: 503)
        }
        for index in 6...7 {
            try await held(index, "GET", "/v1/runs/r1/events").reply(": stream closed\n\n")
        }
        try await held(8, "GET", "/v1/runs/r1/events").reply("data: {\"event\":\"message.delta\",\"delta\":\"ok\",\"seq\":1}\n\n")
        for index in 9...10 {
            try await held(index, "GET", "/v1/runs/r1/events").reply(": stream closed\n\n")
        }
        let events = try await held(11, "GET", "/v1/runs/r1/events")
        XCTAssertTrue(model.isBusy)
        XCTAssertEqual(try store.records(connection: "http://hermes.invalid", bot: bot).count, 1)
        events.open()
        try await finishTurn(events, with: completedTurn("done"))
        await eventually("le tour reprend et finit") { model.conversation.end == .completed }
        XCTAssertTrue(try store.records(connection: "http://hermes.invalid", bot: bot).isEmpty)
        XCTAssertEqual(GateProtocol.requests.filter { $0.request.httpMethod == "POST" }.count, 1)
    }

    func testRepeatedCallsPauseTheThreadWithoutCancellingAndStayOnTheirThread() async throws {
        let model = makeModel()
        try await openEmptyThread(model, session: "thread")
        model.draft = "loop"
        model.send()
        try await held(1, "POST", "/v1/runs").reply(#"{"run_id":"r1"}"#)
        let call = "data: {\"event\":\"tool.started\",\"tool\":\"terminal\",\"preview\":\"repeat\"}\n\n"
        try await held(2, "GET", "/v1/runs/r1/events").reply(String(repeating: call, count: 3) + completedTurn("hidden"))
        await eventually("pause visible") { model.pauseCause != nil }
        XCTAssertEqual(model.pauseCause, .repeatedToolCall(count: 3))
        XCTAssertFalse(model.isBusy)
        model.draft = "do not send"
        XCTAssertFalse(model.canSend)
        model.send()
        XCTAssertFalse(model.conversation.entries.contains { $0.text == "hidden" })
        XCTAssertEqual(GateProtocol.requests.count, 3)
        model.select(bot: "other")
        XCTAssertNil(model.pauseCause)
        model.open(session: "thread", of: bot)
        XCTAssertEqual(model.pauseCause, .repeatedToolCall(count: 3))
    }

    func testClosingAPausedThreadOpensANewSessionWithoutCancellingTheRemoteRun() async throws {
        let model = makeModel()
        XCTAssertNil(model.tokenSignal)
        try await openEmptyThread(model, session: "thread")
        model.draft = "loop"
        model.send()
        try await held(1, "POST", "/v1/runs").reply(#"{"run_id":"r1"}"#)
        let call = "data: {\"event\":\"tool.started\",\"tool\":\"terminal\",\"preview\":\"repeat\"}\n\n"
        try await held(2, "GET", "/v1/runs/r1/events").reply(String(repeating: call, count: 3))
        await eventually("pause visible") { model.pauseCause != nil }
        model.closePausedThread()
        XCTAssertEqual(thread("thread", in: model)?.step, .ready)
        try await held(3, "POST", "/api/sessions").reply(#"{"session":{"id":"fresh"}}"#)
        await eventually("nouveau fil prêt") { model.sessionID == "fresh" && !model.isBusy }
        model.draft = "next"
        XCTAssertTrue(model.canSend)
        XCTAssertNil(model.pauseCause)
        XCTAssertNil(model.tokenSignal)
        XCTAssertFalse(GateProtocol.requests.contains { $0.request.url?.path.hasSuffix("/stop") == true })
    }

    func testCompletedTurnsCalibrateOnlyTheirBotOnTheirConnection() async throws {
        let link = Link(host: hostA, url: "http://host-a.invalid")
        let model = makeModel(link)
        try await openEmptyThread(model, session: "thread")
        for turn in 0..<20 {
            model.draft = "normal"
            model.send()
            try await held(1 + turn * 3, "POST", "/v1/runs").reply(#"{"run_id":"r\#(turn)"}"#)
            let call = "data: {\"event\":\"tool.started\",\"tool\":\"terminal\",\"preview\":\"normal\"}\n\n"
            try await held(2 + turn * 3, "GET", "/v1/runs/r\(turn)/events").reply(call + completedTurn("done"))
            try await held(3 + turn * 3, "GET", "/messages").reply(emptyTranscript)
            await eventually("tour fini") { !model.isBusy }
        }
        model.draft = "calibrated"
        model.send()
        try await held(61, "POST", "/v1/runs").reply(#"{"run_id":"calibrated"}"#)
        let calls = (0..<4).map { "data: {\"event\":\"tool.started\",\"tool\":\"terminal\",\"preview\":\"call-\($0)\"}\n\n" }.joined()
        try await held(62, "GET", "/v1/runs/calibrated/events").reply(calls + completedTurn("hidden"))
        await eventually("seuil appris") { model.pauseCause != nil }
        XCTAssertEqual(model.loopThresholds?.basis, .history(turns: 20))
        XCTAssertEqual(model.pauseCause, .toolCount(count: 4, limit: 3))
        model.select(bot: "other")
        XCTAssertNil(model.loopThresholds)
        model.draft = "cold"
        model.send()
        try await held(63, "POST", "/api/sessions").reply(#"{"session":{"id":"other"}}"#)
        try await held(64, "POST", "/v1/runs").reply(#"{"run_id":"cold"}"#)
        try await held(65, "GET", "/v1/runs/cold/events").reply(calls + completedTurn("done"))
        try await held(66, "GET", "/messages").reply(emptyTranscript)
        await eventually("autre bot fini") { !model.isBusy }
        XCTAssertNil(model.pauseCause)
        XCTAssertEqual(model.loopThresholds?.basis, .coldStart(turns: 0))
        connect(link, to: hostB)
        model.select(bot: bot)
        model.draft = "cold on B"
        model.send()
        try await held(67, "POST", "/api/sessions").reply(#"{"session":{"id":"on-b"}}"#)
        try await held(68, "POST", "/v1/runs").reply(#"{"run_id":"on-b"}"#)
        try await held(69, "GET", "/v1/runs/on-b/events").reply(calls + completedTurn("done"))
        try await held(70, "GET", "/messages").reply(emptyTranscript)
        await eventually("autre hôte fini") { !model.isBusy }
        XCTAssertNil(model.pauseCause)
        XCTAssertEqual(model.loopThresholds?.basis, .coldStart(turns: 0))
    }

    func testAPausedApprovalStaysAvailableForTheBanner() async throws {
        let model = makeModel()
        try await openEmptyThread(model, session: "thread")
        model.draft = "loop"
        model.send()
        try await held(1, "POST", "/v1/runs").reply(#"{"run_id":"r1"}"#)
        let events = try await held(2, "GET", "/v1/runs/r1/events")
        events.open()
        let call = "data: {\"event\":\"tool.started\",\"tool\":\"terminal\",\"preview\":\"repeat\"}\n\n"
        events.send(call + approvalRequest)
        await eventually("approbation reçue") { model.approval != nil }
        try await heldRequest("POST", "/v1/runs/hd-probe-capabilities/approval").reply(availableProbe, status: 404)
        events.send(String(repeating: call, count: 2))
        await eventually("pause visible") { model.pauseCause != nil }
        XCTAssertEqual(model.pausedApproval?.request.command, "/tmp/hv.txt")
        XCTAssertNil(model.approval)
        model.closePausedThread()
        XCTAssertNil(model.pausedApproval)
        try await heldRequest("POST", "/api/sessions").reply(#"{"session":{"id":"fresh"}}"#)
        await eventually("nouveau fil créé") { model.sessionID == "fresh" }
    }

    func testARefusedKeyReportsOneFailureWithoutRetryingTheRun() async throws {
        var failures = 0
        let model = makeModel(onAPIError: { _, _ in failures += 1 })
        try await openEmptyThread(model, session: "thread")
        model.draft = "hello"
        model.send()
        try await held(1, "POST", "/v1/runs").reply(#"{"error":{"message":"refused"}}"#, status: 401)
        await eventually("clé refusée signalée") { failures == 1 }
        XCTAssertNotNil(model.conversation.failure)
        XCTAssertEqual(GateProtocol.requests.count, 2)
    }

    func testRefusedKeysNameTheProfileOfEachFailedRequestNotTheOneOnScreen() async throws {
        var reported: [String] = []
        let model = makeModel(onAPIError: { _, profile in reported.append(profile) })
        try await openEmptyThread(model, session: "a")
        model.draft = "go"
        model.send()
        let first = try await held(1, "POST", "/v1/runs")
        model.open(session: "b", of: "other-bot")
        try await held(2, "GET", "/api/sessions/b/messages").reply(emptyTranscript)
        await eventually("autre bot à l'écran") { model.botID == "other-bot" && !model.isLoading }
        model.draft = "go"
        model.send()
        let second = try await held(3, "POST", "/v1/runs")
        second.reply(#"{"error":{"message":"refused"}}"#, status: 401)
        first.reply(#"{"error":{"message":"refused"}}"#, status: 401)
        await eventually("deux refus signalés") { reported.count == 2 }
        XCTAssertEqual(reported.sorted(), ["hv-bot", "other-bot"])
        XCTAssertEqual(model.botID, "other-bot")
    }

    // MARK: nouvelle session

    func testSendingWhileANewSessionIsBeingCreatedIsRefusedAndTheMessageThenGoesToTheNewSession() async throws {
        let model = makeModel()
        try await openEmptyThread(model, session: "old")
        model.draft = "pour le nouveau fil"
        XCTAssertTrue(model.canSend)

        model.newSession()
        let creation = try await held(1, "POST", "/api/sessions")
        XCTAssertFalse(model.canSend, "pendant la création, Envoyer partirait dans l'ancien fil puis la création vide l'écran")
        model.send()
        XCTAssertTrue(model.conversation.entries.isEmpty, "l'envoi refusé n'ajoute aucune ligne")
        XCTAssertEqual(model.draft, "pour le nouveau fil", "le brouillon reste")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(GateProtocol.requests.count, 2, "aucun envoi ne part pendant la création")

        creation.reply(#"{"session":{"id":"new"}}"#)
        await eventually("fil créé") { model.sessionID == "new" }
        XCTAssertTrue(model.canSend, "la création finie, Envoyer est de nouveau permis")
        XCTAssertTrue(model.conversation.entries.isEmpty)
        model.send()
        let run = try await held(2, "POST", "/v1/runs")
        XCTAssertEqual(run.json?["session_id"] as? String, "new", "le message part dans le nouveau fil")
        XCTAssertEqual(run.json?["input"] as? String, "pour le nouveau fil")
    }

    func testANewSessionThatFailsShowsItsErrorOnTheNewThreadAndTheNextSendCreatesIt() async throws {
        let model = makeModel()
        try await openEmptyThread(model, session: "old")
        model.draft = "après l'échec"
        model.newSession()
        let creation = try await held(1, "POST", "/api/sessions")
        XCTAssertFalse(model.canSend)
        XCTAssertNil(model.sessionID, "l'écran passe sur le fil de « Nouvelle session », pas encore créé")
        creation.reply(#"{"error":"hv"}"#, status: 500)
        await eventually("échec affiché") { model.conversation.failure != nil }
        XCTAssertNil(model.sessionID)
        XCTAssertTrue(model.canSend, "le brouillon reste et peut partir")
        model.send()
        try await held(2, "POST", "/api/sessions").reply(#"{"session":{"id":"new"}}"#)
        let run = try await held(3, "POST", "/v1/runs")
        XCTAssertEqual(run.json?["session_id"] as? String, "new", "le premier envoi crée le fil")
        XCTAssertEqual(run.json?["input"] as? String, "après l'échec")
    }

    func testLeavingForAnotherThreadWhileANewSessionIsBeingCreatedKeepsTheOpenedThreadAndFreesTheComposer() async throws {
        let model = makeModel()
        try await openEmptyThread(model, session: "old")
        model.newSession()
        let creation = try await held(1, "POST", "/api/sessions")
        model.open(session: "other", of: bot)
        try await held(2, "GET", "/api/sessions/other/messages").reply(transcript((7, "user", "déjà là"), (8, "assistant", "réponse")))
        await eventually("transcript lu") { !model.isLoading }
        creation.reply(#"{"session":{"id":"new"}}"#)
        model.draft = "suite"
        await eventually("composeur libéré") { model.canSend }
        XCTAssertEqual(model.sessionID, "other", "la création abandonnée ne remplace pas le fil ouvert")
        XCTAssertEqual(model.conversation.entries.map(\.text), ["déjà là", "réponse"])
    }

    // MARK: le premier envoi d'un fil neuf

    func testSwitchingBotWhileTheFirstSendCreatesItsThreadStillSendsTheMessageThere() async throws {
        let model = makeModel()
        model.select(bot: bot)
        model.draft = "premier message"
        model.send()
        let creation = try await held(0, "POST", "/api/sessions")

        model.select(bot: "hv-other")
        creation.reply(#"{"session":{"id":"new"}}"#)
        // le message accepté part dans le fil créé, chez le bot où il a été écrit
        let run = try await held(1, "POST", "/v1/runs")
        XCTAssertEqual(run.request.url?.path, "/p/\(bot)/v1/runs")
        XCTAssertEqual(run.json?["session_id"] as? String, "new")
        XCTAssertEqual(run.json?["input"] as? String, "premier message")
        XCTAssertEqual(model.botID, "hv-other")
        XCTAssertTrue(model.conversation.entries.isEmpty, "l'écran reste celui de l'autre bot")

        run.reply(#"{"run_id":"r1"}"#)
        try await held(2, "GET", "/v1/runs/r1/events").reply(completedTurn("réponse"))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(GateProtocol.requests.count, 3, "la fin du tour ne relit pas le fil d'un autre bot")
        XCTAssertTrue(model.conversation.entries.isEmpty, "la fin du tour ne change pas l'écran de l'autre bot")

        // retour sur le fil créé : le tour est fini, Envoyer est permis
        model.open(session: "new", of: bot)
        try await held(3, "GET", "/api/sessions/new/messages").reply(transcript((1, "user", "premier message"), (2, "assistant", "réponse")))
        // le fil garde ses lignes pendant la lecture : on attend la fin de la lecture, pas les lignes
        await eventually("transcript lu") { !model.isLoading }
        XCTAssertEqual(model.conversation.entries.map(\.serverIndex), [1, 2])
        XCTAssertEqual(model.conversation.entries.map(\.text), ["premier message", "réponse"])
        XCTAssertEqual(model.conversation.end, .completed, "l'état final du tour est resté sur son fil")
        model.draft = "suite"
        XCTAssertTrue(model.canSend)
    }

    func testAStartingTurnKeepsItsIdForTheRunItStarts() async throws {
        let model = makeModel()
        try await openEmptyThread(model, session: "s")
        model.draft = "message"
        model.send()
        let start = try await held(1, "POST", "/v1/runs")
        let starting = model.startingTurns()
        XCTAssertEqual(starting.count, 1)
        start.reply(#"{"run_id":"r1"}"#)
        await eventually("run suivi") { !model.runningTurns.isEmpty }
        XCTAssertEqual(model.startingTurns(), [])
        XCTAssertEqual(model.runningTurns.map(\.turn), starting)
        try await held(2, "GET", "/v1/runs/r1/events").reply(completedTurn("réponse"))
        // la fin du tour relit le fil : la relecture ne doit pas déborder sur le test suivant
        try await held(3, "GET", "/api/sessions/s/messages").reply(transcript((1, "user", "message"), (2, "assistant", "réponse")))
        await eventually("transcript relu") { !model.isLoading }
    }

    func testAStartingTurnKeepsItsIdWhenItsThreadIsCreated() async throws {
        let model = makeModel()
        model.select(bot: bot)
        model.draft = "premier message"
        model.send()
        let creation = try await held(0, "POST", "/api/sessions")
        let starting = model.startingTurns()
        XCTAssertEqual(starting.count, 1)
        creation.reply(#"{"session":{"id":"new"}}"#)
        let start = try await held(1, "POST", "/v1/runs")
        XCTAssertEqual(model.startingTurns(), starting, "le fil créé garde l'id du tour qui démarre")
        start.reply(#"{"run_id":"r1"}"#)
        await eventually("run suivi") { !model.runningTurns.isEmpty }
        XCTAssertEqual(model.runningTurns.map(\.turn), starting)
        try await held(2, "GET", "/v1/runs/r1/events").reply(completedTurn("réponse"))
        try await held(3, "GET", "/api/sessions/new/messages").reply(transcript((1, "user", "premier message"), (2, "assistant", "réponse")))
        await eventually("transcript relu") { !model.isLoading }
    }

    func testTwoStartAttemptsKeepDistinctIdsAndOnlyTheConfirmedAttemptBindsTheRun() async throws {
        let model = makeModel()
        try await openEmptyThread(model, session: "thread")
        model.draft = "first"
        model.send()
        let firstStart = try await held(1, "POST", "/v1/runs")
        let first = try XCTUnwrap(model.startingTurns().first)
        firstStart.reply(#"{"error":"hv"}"#, status: 500)
        await eventually("échec affiché") { model.conversation.failure != nil }
        model.draft = "again"
        model.send()
        let secondStart = try await held(2, "POST", "/v1/runs")
        let second = try XCTUnwrap(model.startingTurns().first)
        XCTAssertNotEqual(first, second)
        secondStart.reply(#"{"run_id":"r2"}"#)
        await eventually("run suivi") { !model.runningTurns.isEmpty }
        XCTAssertEqual(model.startingTurns(), [])
        XCTAssertEqual(model.runningTurns.map(\.turn), [second])
        try await held(3, "GET", "/v1/runs/r2/events").reply(completedTurn("réponse"))
        try await held(4, "GET", "/api/sessions/thread/messages").reply(transcript((1, "user", "again"), (2, "assistant", "réponse")))
        await eventually("transcript relu") { !model.isLoading }
    }

    func testANewSessionStartedWhileTheFirstSendCreatesItsThreadLeavesTheMessageInThatThread() async throws {
        let model = makeModel()
        model.select(bot: bot)
        model.draft = "premier message"
        model.send()
        let firstCreation = try await held(0, "POST", "/api/sessions")

        model.newSession()
        let freshCreation = try await held(1, "POST", "/api/sessions")
        firstCreation.reply(#"{"session":{"id":"first"}}"#)
        let run = try await held(2, "POST", "/v1/runs")
        XCTAssertEqual(run.json?["session_id"] as? String, "first", "le message part dans le fil créé pour lui, pas dans la nouvelle session")
        XCTAssertEqual(run.json?["input"] as? String, "premier message")

        freshCreation.reply(#"{"session":{"id":"fresh"}}"#)
        await eventually("nouvelle session ouverte") { model.sessionID == "fresh" }
        XCTAssertTrue(model.conversation.entries.isEmpty)
    }

    // MARK: l'écran change entre l'envoi et le départ de sa tâche

    /// Envoie dans le fil « original », puis change d'écran dans le même tour de boucle : la tâche d'envoi ne démarre qu'après
    /// Le message accepté part dans le fil et chez le bot où il a été écrit ; rend sa requête `start_run`, encore en attente
    private func sendInOriginalThenLeave(_ model: ConversationModel, _ leave: () -> Void) async throws -> GateProtocol {
        try await openEmptyThread(model, session: "original")
        model.draft = "belongs to original"
        model.send()
        leave()
        let run = try await heldRequest("POST", "/v1/runs")
        XCTAssertEqual(run.request.url?.path, "/p/\(bot)/v1/runs", "le bot où le message a été écrit")
        XCTAssertEqual(run.json?["session_id"] as? String, "original", "le fil où le message a été écrit")
        XCTAssertEqual(run.json?["input"] as? String, "belongs to original")
        return run
    }

    func testOpeningAnotherThreadRightAfterASendStillSendsTheMessageInTheThreadItWasWrittenIn() async throws {
        let model = makeModel()
        let run = try await sendInOriginalThenLeave(model) { model.open(session: "other", of: bot) }
        try await heldRequest("GET", "/api/sessions/other/messages").reply(transcript((7, "user", "autre"), (8, "assistant", "fil")))
        await eventually("transcript lu") { !model.isLoading }
        XCTAssertEqual(model.sessionID, "other")

        run.reply(#"{"run_id":"r1"}"#)
        try await heldRequest("GET", "/v1/runs/r1/events").reply(completedTurn("reply"))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.conversation.entries.map(\.text), ["autre", "fil"], "la fin du tour de original ne change pas l'écran de other")
        XCTAssertEqual(GateProtocol.requests.count, 4, "la fin du tour ne relit pas le fil original")
    }

    func testOpeningAThreadOfAnotherBotRightAfterASendStillSendsTheMessageInTheThreadItWasWrittenIn() async throws {
        let model = makeModel()
        let run = try await sendInOriginalThenLeave(model) { model.open(session: "elsewhere", of: "hv-other") }
        let transcriptRequest = try await heldRequest("GET", "/api/sessions/elsewhere/messages")
        XCTAssertEqual(transcriptRequest.request.url?.path, "/p/hv-other/api/sessions/elsewhere/messages")
        transcriptRequest.reply(transcript((3, "user", "ailleurs")))
        await eventually("transcript lu") { !model.isLoading }
        XCTAssertEqual(model.botID, "hv-other")
        XCTAssertEqual(model.sessionID, "elsewhere")

        run.reply(#"{"run_id":"r1"}"#)
        try await heldRequest("GET", "/v1/runs/r1/events").reply(completedTurn("reply"))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.conversation.entries.map(\.text), ["ailleurs"], "la fin du tour ne change pas l'écran de l'autre bot")
        XCTAssertEqual(GateProtocol.requests.count, 4, "la fin du tour ne relit rien")
    }

    func testSelectingAnotherBotRightAfterASendOnAnExistingThreadDoesNotCreateAThreadForTheMessage() async throws {
        let model = makeModel()
        let run = try await sendInOriginalThenLeave(model) { model.select(bot: "hv-other") }
        XCTAssertEqual(model.botID, "hv-other")
        XCTAssertNil(model.sessionID)

        run.reply(#"{"run_id":"r1"}"#)
        try await heldRequest("GET", "/v1/runs/r1/events").reply(completedTurn("reply"))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.conversation.entries.isEmpty, "la fin du tour ne change pas l'écran de l'autre bot")
        XCTAssertEqual(GateProtocol.requests.count, 3, "aucun fil créé, aucune relecture")
        XCTAssertNil(model.sessionID)
    }

    func testANewSessionRightAfterASendLeavesTheMessageInTheThreadItWasWrittenIn() async throws {
        let model = makeModel()
        let run = try await sendInOriginalThenLeave(model) { model.newSession() }
        try await heldRequest("POST", "/api/sessions").reply(#"{"session":{"id":"fresh"}}"#)
        await eventually("nouvelle session ouverte") { model.sessionID == "fresh" }
        XCTAssertTrue(model.conversation.entries.isEmpty)

        run.reply(#"{"run_id":"r1"}"#)
        try await heldRequest("GET", "/v1/runs/r1/events").reply(completedTurn("reply"))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.conversation.entries.isEmpty, "la fin du tour ne change pas la nouvelle session")
        XCTAssertEqual(model.sessionID, "fresh")
    }

    // MARK: deux tours

    func testASecondSendWhileTheFirstTurnIsBeingReadAgainKeepsItsMessageAndTheTurnGoesOn() async throws {
        let model = makeModel()
        try await openEmptyThread(model, session: "thread")
        model.draft = "first"
        model.send()
        try await held(1, "POST", "/v1/runs").reply(#"{"run_id":"r1"}"#)
        try await held(2, "GET", "/v1/runs/r1/events").reply(completedTurn("reply"))
        // le tour est fini, la relecture du transcript attend la réponse de Hermes
        let staleReread = try await held(3, "GET", "/api/sessions/thread/messages")
        await eventually("tour fini") { model.conversation.end == .completed }

        model.draft = "second"
        XCTAssertTrue(model.canSend, "le tour est fini : le second message peut partir sans attendre la relecture")
        model.send()
        XCTAssertEqual(model.conversation.entries.map(\.text), ["first", "reply", "second"])
        // la relecture du premier tour répond avec un transcript d'avant le second message
        staleReread.reply(transcript((1, "user", "first"), (2, "assistant", "reply")))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.conversation.entries.map(\.text), ["first", "reply", "second"], "une relecture dépassée n'efface pas le message envoyé depuis")
        XCTAssertEqual(model.conversation.phase, .running, "le second tour est toujours en cours")

        try await held(4, "POST", "/v1/runs").reply(#"{"run_id":"r2"}"#)
        try await held(5, "GET", "/v1/runs/r2/events").reply(completedTurn("reply 2"))
        let reread = try await held(6, "GET", "/api/sessions/thread/messages")
        reread.reply(transcript((1, "user", "first"), (2, "assistant", "reply"), (3, "user", "second"), (4, "assistant", "reply 2")))
        await eventually("lignes numérotées") { model.conversation.entries.compactMap(\.serverIndex) == [1, 2, 3, 4] }
        XCTAssertEqual(model.conversation.entries.map(\.text), ["first", "reply", "second", "reply 2"])
        XCTAssertEqual(model.conversation.end, .completed)
        XCTAssertEqual(model.conversation.phase, .idle)
    }

    // MARK: un tour qui tourne chez Hermes pendant qu'on rouvre ou qu'on quitte son fil

    /// Cas 2 et P1 @ 344d2501 : un clic sur le fil dont le tour tourne ne relit rien, refuse un second run, puis montre la réponse et l'état final
    func testReopeningTheThreadOfARunningTurnRefusesASendThenShowsItsReplyAndItsEnd() async throws {
        let model = makeModel()
        try await openEmptyThread(model, session: "thread")
        model.draft = "first"
        model.send()
        try await held(1, "POST", "/v1/runs").reply(#"{"run_id":"r1"}"#)
        let events = try await held(2, "GET", "/v1/runs/r1/events")

        model.open(session: "thread", of: bot)
        XCTAssertEqual(model.conversation.entries.map(\.text), ["first"], "le fil rouvert montre le tour en cours")
        model.draft = "second"
        XCTAssertFalse(model.canSend, "le premier tour tourne encore chez Hermes : un second run partirait en double dans ce fil")
        XCTAssertTrue(model.isBusy, "l'écran dit pourquoi Envoyer est grisé")
        model.send()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(GateProtocol.requests.count, 3, "ni relecture ni second run")
        XCTAssertEqual(model.draft, "second", "le brouillon reste")

        events.reply(completedTurn("reply"))
        try await held(3, "GET", "/api/sessions/thread/messages").reply(transcript((1, "user", "first"), (2, "assistant", "reply")))
        await eventually("lignes numérotées") { model.conversation.entries.compactMap(\.serverIndex) == [1, 2] }
        XCTAssertEqual(model.conversation.entries.map(\.text), ["first", "reply"])
        XCTAssertEqual(model.conversation.end, .completed, "l'état final reste après la réouverture")
        XCTAssertTrue(model.canSend, "le tour est fini : Envoyer est de nouveau permis")
        XCTAssertFalse(model.isBusy)
    }

    /// P1 @ 344d2501, avec `run.failed` : l'état et l'erreur de Hermes restent après la réouverture et après la relecture
    func testReopeningTheThreadOfARunningTurnShowsTheFailureAndTheErrorHermesGives() async throws {
        let model = makeModel()
        try await openEmptyThread(model, session: "thread")
        model.draft = "first"
        model.send()
        try await held(1, "POST", "/v1/runs").reply(#"{"run_id":"r1"}"#)
        let events = try await held(2, "GET", "/v1/runs/r1/events")
        model.open(session: "thread", of: bot)

        events.reply(failedTurn("HTTP 400: hv fake provider failure"))
        await eventually("état final affiché") { model.conversation.end == .failed }
        XCTAssertEqual(model.conversation.endDetail, "HTTP 400: hv fake provider failure")
        try await held(3, "GET", "/api/sessions/thread/messages").reply(transcript((1, "user", "first")))
        await eventually("transcript relu") { model.conversation.entries.first?.serverIndex == 1 }
        XCTAssertEqual(model.conversation.end, .failed, "la relecture garde l'état final")
        XCTAssertEqual(model.conversation.endDetail, "HTTP 400: hv fake provider failure")
    }

    /// P1 @ 344d2501 : le tour finit pendant que son fil est quitté, l'état final est là quand on y revient
    func testATurnThatEndsWhileItsThreadIsLeftShowsItsEndWhenTheThreadIsReopened() async throws {
        let model = makeModel()
        try await openEmptyThread(model, session: "a")
        model.draft = "first"
        model.send()
        try await held(1, "POST", "/v1/runs").reply(#"{"run_id":"r1"}"#)
        let events = try await held(2, "GET", "/v1/runs/r1/events")
        model.open(session: "b", of: bot)
        try await held(3, "GET", "/api/sessions/b/messages").reply(emptyTranscript)
        events.reply(failedTurn("HTTP 400: hv fake provider failure"))
        await eventually("tour fini dans son fil") { thread("a", in: model)?.step == .ready }
        XCTAssertNil(model.conversation.end, "l'écran de b ne change pas")
        XCTAssertEqual(GateProtocol.requests.count, 4, "aucune relecture d'un fil quitté")

        model.open(session: "a", of: bot)
        try await held(4, "GET", "/api/sessions/a/messages").reply(transcript((1, "user", "first")))
        await eventually("transcript lu") { !model.isLoading }
        XCTAssertEqual(model.conversation.entries.map(\.text), ["first"])
        XCTAssertEqual(model.conversation.end, .failed)
        XCTAssertEqual(model.conversation.endDetail, "HTTP 400: hv fake provider failure")
    }

    func testLeavingARunningThreadFreesTheOtherThreadAndItsEndLeavesTheOtherScreenAlone() async throws {
        let model = makeModel()
        try await openEmptyThread(model, session: "a")
        model.draft = "first"
        model.send()
        try await held(1, "POST", "/v1/runs").reply(#"{"run_id":"r1"}"#)
        let events = try await held(2, "GET", "/v1/runs/r1/events")

        model.open(session: "b", of: bot)
        try await held(3, "GET", "/api/sessions/b/messages").reply(transcript((7, "user", "autre"), (8, "assistant", "fil")))
        await eventually("transcript lu") { !model.isLoading }
        model.draft = "suite"
        XCTAssertTrue(model.canSend, "le tour qui tourne est dans un autre fil")
        model.send()
        let runB = try await held(4, "POST", "/v1/runs")
        XCTAssertEqual(runB.json?["session_id"] as? String, "b")

        events.reply(completedTurn("reply"))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(GateProtocol.requests.count, 5, "la fin du tour de a ne relit pas le fil b")
        XCTAssertEqual(model.conversation.entries.map(\.text), ["autre", "fil", "suite"], "la fin du tour de a ne change pas l'écran de b")
        XCTAssertEqual(model.conversation.phase, .running)
    }

    func testReopeningAThreadWhoseTurnIsStillRunningAfterLeavingItRefusesASend() async throws {
        let model = makeModel()
        try await openEmptyThread(model, session: "a")
        model.draft = "first"
        model.send()
        try await held(1, "POST", "/v1/runs").reply(#"{"run_id":"r1"}"#)
        let events = try await held(2, "GET", "/v1/runs/r1/events")
        model.open(session: "b", of: bot)
        try await held(3, "GET", "/api/sessions/b/messages").reply(emptyTranscript)
        await eventually("transcript lu") { !model.isLoading }

        // retour sur a : son tour tourne toujours, l'écran le suit sans rien relire
        model.open(session: "a", of: bot)
        XCTAssertEqual(model.conversation.entries.map(\.text), ["first"])
        model.draft = "second"
        XCTAssertFalse(model.canSend)
        XCTAssertTrue(model.isBusy)
        events.reply(completedTurn("reply"))
        // le tour fini, le fil ouvert se relit
        try await held(4, "GET", "/api/sessions/a/messages").reply(transcript((1, "user", "first"), (2, "assistant", "reply")))
        await eventually("composeur libéré") { model.canSend }
        await eventually("lignes numérotées") { model.conversation.entries.compactMap(\.serverIndex) == [1, 2] }
        XCTAssertEqual(model.conversation.entries.map(\.text), ["first", "reply"])
        XCTAssertEqual(model.conversation.end, .completed)
    }

    func testATurnWhoseReadFailsAfterItsThreadWasReopenedFreesTheComposer() async throws {
        let model = makeModel()
        try await openEmptyThread(model, session: "thread")
        model.draft = "first"
        model.send()
        try await held(1, "POST", "/v1/runs").reply(#"{"run_id":"r1"}"#)
        let events = try await held(2, "GET", "/v1/runs/r1/events")
        model.open(session: "thread", of: bot)
        model.draft = "second"
        XCTAssertFalse(model.canSend)

        events.reply(#"{"error":"hv"}"#, status: 500)
        await eventually("composeur libéré") { model.canSend }
        XCTAssertNotNil(model.conversation.failure, "l'erreur de lecture du tour s'affiche dans son fil")
        XCTAssertEqual(model.conversation.entries.map(\.text), ["first"])
    }

    // MARK: Hermes injoignable (P2 @ 344d2501)

    /// Sans client, « Nouvelle session » sur un bot puis un autre bot avant le départ de la tâche : l'erreur reste sur le fil de « Nouvelle session »
    func testANewSessionWithoutHermesThenABotSwitchKeepsTheErrorOnItsOwnThread() async throws {
        let model = makeModel(reachable: false)
        model.select(bot: bot)
        model.newSession()
        model.select(bot: "hv-other")
        await eventually("erreur rangée") { model.machine.threads.values.contains { $0.conversation.failure != nil } }
        XCTAssertEqual(model.botID, "hv-other")
        XCTAssertNil(model.conversation.failure, "une création quittée n'affiche jamais son erreur chez un autre bot")
        model.select(bot: bot)
        XCTAssertEqual(model.conversation.failure, "Hermes n'est pas joignable.", "retour sur le bot : l'erreur est sur le fil de « Nouvelle session »")
        XCTAssertTrue(GateProtocol.requests.isEmpty)
    }

    func testAFirstSendWithoutHermesThenABotSwitchKeepsTheMessageAndTheErrorOnItsOwnThread() async throws {
        let model = makeModel(reachable: false)
        model.select(bot: bot)
        model.draft = "premier message"
        model.send()
        model.select(bot: "hv-other")
        await eventually("erreur rangée") { model.machine.threads.values.contains { $0.conversation.failure != nil } }
        XCTAssertNil(model.conversation.failure)
        XCTAssertTrue(model.conversation.entries.isEmpty)
        model.select(bot: bot)
        XCTAssertEqual(model.conversation.entries.map(\.text), ["premier message"], "le message n'est pas perdu")
        XCTAssertEqual(model.conversation.failure, "Hermes n'est pas joignable.")
    }

    func testOpeningAThreadWithoutHermesThenABotSwitchKeepsTheErrorOnThatThread() async throws {
        let model = makeModel(reachable: false)
        model.open(session: "thread", of: bot)
        model.select(bot: "hv-other")
        await eventually("erreur rangée") { thread("thread", in: model)?.conversation.failure != nil }
        XCTAssertEqual(thread("thread", in: model)?.step, .ready)
        XCTAssertNil(model.conversation.failure)
        XCTAssertFalse(model.isLoading)
    }

    func testAStartRunThatFailsFreesTheComposerForThatThread() async throws {
        let model = makeModel()
        try await openEmptyThread(model, session: "thread")
        model.draft = "first"
        model.send()
        let start = try await held(1, "POST", "/v1/runs")
        XCTAssertTrue(model.isBusy)
        start.reply(#"{"error":"hv"}"#, status: 500)
        await eventually("échec affiché") { model.conversation.failure != nil }
        model.draft = "again"
        XCTAssertTrue(model.canSend, "aucun tour ne tourne : le fil n'est pas bloqué")
        XCTAssertFalse(model.isBusy)
    }

    func testTheReadAgainOfAFinishedTurnGivesItsLinesTheirServerIndex() async throws {
        let model = makeModel()
        try await openEmptyThread(model, session: "thread")
        model.draft = "first"
        model.send()
        try await held(1, "POST", "/v1/runs").reply(#"{"run_id":"r1"}"#)
        try await held(2, "GET", "/v1/runs/r1/events").reply(completedTurn("reply"))
        try await held(3, "GET", "/api/sessions/thread/messages").reply(transcript((1, "user", "first"), (2, "assistant", "reply")))
        await eventually("lignes numérotées") { model.conversation.entries.compactMap(\.serverIndex) == [1, 2] }
        XCTAssertEqual(model.conversation.end, .completed)
    }

    // MARK: changer le modèle de la session (HD-10)

    private let lockReply = #"{"object":"hermes.session.model_lock","session_id":"t","runtime":{"provider":"","model":"%@","model_lock":"accepted"}}"#

    private func profiles(_ models: [String?]) -> @MainActor () -> [Bot] {
        { models.enumerated().map { Bot(id: $0.offset == 0 ? "hv-bot" : "bot-\($0.offset)", name: "Bot \($0.offset)", model: $0.element) } }
    }

    /// Lane 1 : le choix part en `set_model` sur la session ouverte, et le sélecteur change à la réponse
    func testPickingAModelPostsItToTheOpenSessionOnlyAndTheSelectorChangesWhenHermesAnswers() async throws {
        let model = makeModel(bots: profiles(["profil-m", "model-y"]))
        try await openEmptyThread(model, session: "t")
        XCTAssertEqual(model.shownModel, "profil-m", "avant tout choix, le fil suit le modèle du profil")

        model.pick(model: "model-y")
        let lock = try await held(1, "POST", "/api/sessions/t/model")
        XCTAssertEqual(lock.request.url?.path, "/p/\(bot)/api/sessions/t/model")
        XCTAssertEqual(lock.json as? [String: String], ["model": "model-y"])
        XCTAssertTrue(model.isModelPending)
        XCTAssertEqual(model.shownModel, "profil-m", "le sélecteur attend la confirmation")

        lock.reply(String(format: lockReply, "model-y"))
        await eventually("modèle confirmé") { model.shownModel == "model-y" }
        XCTAssertFalse(model.isModelPending)
        XCTAssertEqual(GateProtocol.requests.count, 2, "une lecture du fil et un set_model, rien d'autre : le modèle du profil n'est jamais écrit")
    }

    /// Lane 6
    func testTheSameOptionTwiceFastSendsOneSetModel() async throws {
        let model = makeModel(bots: profiles(["profil-m", "model-y"]))
        try await openEmptyThread(model, session: "t")
        model.pick(model: "model-y")
        model.pick(model: "model-y")
        let lock = try await held(1, "POST", "/api/sessions/t/model")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(GateProtocol.requests.count, 2)
        lock.reply(String(format: lockReply, "model-y"))
        await eventually("modèle confirmé") { model.shownModel == "model-y" }
        model.pick(model: "model-y")
        model.pick(model: "profil-m")
        try await held(2, "POST", "/api/sessions/t/model")
        XCTAssertEqual(GateProtocol.requests.count, 3, "le modèle déjà montré ne se redemande pas ; un autre choix part")
    }

    func testPickingTheModelThatTheSelectorShowsAsksNothing() async throws {
        let model = makeModel(bots: profiles(["profil-m"]))
        try await openEmptyThread(model, session: "t")
        model.pick(model: "profil-m")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(GateProtocol.requests.count, 1)
        XCTAssertFalse(model.isModelPending)
    }

    /// `POST /v1/runs` ignore le verrou de la session (S4) : le modèle choisi part dans le corps de chaque run du fil
    func testTheChosenModelGoesInTheBodyOfTheNextRun() async throws {
        let model = makeModel(bots: profiles(["profil-m"]))
        try await openEmptyThread(model, session: "t")
        model.pick(model: "model-y")
        try await held(1, "POST", "/api/sessions/t/model").reply(String(format: lockReply, "model-y"))
        await eventually("modèle confirmé") { model.shownModel == "model-y" }
        model.draft = "avec choix"
        model.send()
        let run = try await held(2, "POST", "/v1/runs")
        XCTAssertEqual(run.json?["model"] as? String, "model-y")
        XCTAssertEqual(run.json?["session_id"] as? String, "t")
    }

    func testAThreadWithoutChoiceSendsNoModelSoItFollowsTheProfile() async throws {
        let model = makeModel(bots: profiles(["profil-m"]))
        try await openEmptyThread(model, session: "t")
        model.draft = "sans choix"
        model.send()
        let run = try await held(1, "POST", "/v1/runs")
        XCTAssertNil(run.json?["model"])
    }

    func testAnUnconfirmedPickLeavesTheRunsOnTheModelThatTheSelectorShows() async throws {
        let model = makeModel(bots: profiles(["profil-m"]))
        try await openEmptyThread(model, session: "t")
        model.pick(model: "model-y")
        try await held(1, "POST", "/api/sessions/t/model")
        model.draft = "pendant l'attente"
        model.send()
        let run = try await heldRequest("POST", "/v1/runs")
        XCTAssertNil(run.json?["model"], "le modèle montré est celui du profil tant que Hermes n'a pas confirmé")
    }

    /// Lane 9
    func testAThreadOpenedFromTheListTakesTheModelOfItsEntryAndSendsItWithEveryRun() async throws {
        let model = makeModel(bots: profiles(["profil-m"]), listedThread: { bot, session in bot == "hv-bot" && session == "t" ? (model: "hv-fake-2", read: 1) : nil })
        try await openEmptyThread(model, session: "t")
        XCTAssertEqual(model.shownModel, "hv-fake-2")
        model.draft = "suite"
        model.send()
        let run = try await heldRequest("POST", "/v1/runs")
        XCTAssertEqual(run.json?["model"] as? String, "hv-fake-2")
    }

    /// Lane 3 : un nom que l'app ne connaît pas s'affiche tel que Hermes l'envoie, et reste un choix du sélecteur
    func testAnUnknownModelNameShowsAsSentAndStaysAnOption() async throws {
        let model = makeModel(bots: profiles(["profil-m", "m1", nil, "m1"]), listedThread: { _, _ in (model: "Inconnu (x) 9 é", read: 1) })
        try await openEmptyThread(model, session: "t")
        XCTAssertEqual(model.shownModel, "Inconnu (x) 9 é")
        XCTAssertEqual(model.modelOptions, ["Inconnu (x) 9 é", "m1", "profil-m"], "les modèles des profils sans doublon, plus celui du fil")
    }

    func testTheOptionsWithoutAnyProfileModelAreEmptyAndAnOpenThreadWithoutModelShowsNone() async throws {
        let model = makeModel(bots: profiles([nil]))
        try await openEmptyThread(model, session: "t")
        XCTAssertNil(model.shownModel)
        XCTAssertEqual(model.modelOptions, [])
    }

    func testARefusedPickKeepsTheModelNamesTheErrorAndLooksAtTheRouteAgain() async throws {
        let model = makeModel(bots: profiles(["profil-m"]))
        try await openEmptyThread(model, session: "t")
        model.pick(model: "model-y")
        try await held(1, "POST", "/api/sessions/t/model").reply(#"{"error":{"message":"modèle refusé","code":"bad"}}"#, status: 400)
        await eventually("erreur montrée") { model.modelError != nil }
        XCTAssertTrue(model.modelError?.contains("modèle refusé") == true, "\(model.modelError ?? "")")
        XCTAssertEqual(model.shownModel, "profil-m")
        XCTAssertFalse(model.isModelPending)
        XCTAssertNil(model.conversation.failure, "l'échec du verrou n'est pas un échec du tour")

        // la route a-t-elle disparu ? la sonde de `set_model` le dit, sans la carte entière
        let probe = try await held(2, "POST", "/api/sessions/hd-probe-capabilities/model")
        XCTAssertEqual(probe.json as? [String: String], ["model": ""])
        probe.reply(#"{"error":{"code":"session_not_found","message":"x"}}"#, status: 404)
        await eventually("sonde finie") { model.modelSupport == .available }
        XCTAssertEqual(GateProtocol.requests.count, 3)
    }

    /// Lane 4 : une route retirée désactive le sélecteur seul, avec son message
    func testADroppedSetModelRouteDisablesTheSelectorAloneWithItsMessage() async throws {
        let model = makeModel(bots: profiles(["profil-m"]))
        model.select(bot: bot)
        XCTAssertEqual(model.modelSupport, .unknown, "tant que Hermes n'a pas répondu, le sélecteur reste libre")
        let check = Task { await model.checkModelSupport() }
        try await held(0, "POST", "/api/sessions/hd-probe-capabilities/model").reply(#"{"error":"404: Not Found"}"#, status: 404)
        await check.value
        XCTAssertEqual(model.modelSupport, .disabled(message: "Fonction désactivée (le changement de modèle) : Hermes ne propose plus cette route."))
        model.draft = "ça marche"
        XCTAssertTrue(model.canSend, "l'envoi reste permis")
        model.pick(model: "model-y")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(GateProtocol.requests.count, 1, "un sélecteur désactivé ne demande rien")
    }

    func testTheRouteIsProbedOnceAndAnOutageLeavesTheSelectorFree() async throws {
        let model = makeModel(bots: profiles(["profil-m"]))
        model.select(bot: bot)
        let first = Task { await model.checkModelSupport() }
        try await held(0, "POST", "/api/sessions/hd-probe-capabilities/model").reply("", status: 503)
        await first.value
        XCTAssertEqual(model.modelSupport, .unknown, "une panne ne désactive rien : on redemandera")

        let second = Task { await model.checkModelSupport() }
        try await held(1, "POST", "/api/sessions/hd-probe-capabilities/model").reply(#"{"error":{"code":"session_not_found","message":"x"}}"#, status: 404)
        await second.value
        XCTAssertEqual(model.modelSupport, .available)
        await model.checkModelSupport()
        XCTAssertEqual(GateProtocol.requests.count, 2, "la réponse reste en mémoire")
    }

    /// La liste des fils d'une barre latérale qui change entre deux ouvertures : `read` monte à chaque relecture
    @MainActor
    private final class ListedModel {
        var value: String?
        var read = 0
    }

    /// Un fil rouvert prend le modèle que la liste lui donne depuis sa dernière ouverture, et le run suivant le porte
    func testAReopenedThreadTakesTheModelThatTheListGaveInTheMeantime() async throws {
        let listed = ListedModel()
        let model = makeModel(bots: profiles(["profil-m"]), listedThread: { _, _ in (model: listed.value, read: listed.read) })
        try await openEmptyThread(model, session: "t")
        XCTAssertEqual(model.shownModel, "profil-m")
        model.open(session: "u", of: bot)
        try await held(1, "GET", "/api/sessions/u/messages").reply(emptyTranscript)
        await eventually("transcript lu") { !model.isLoading }

        listed.value = "server-new-model"
        listed.read = 1
        model.open(session: "t", of: bot)
        try await held(2, "GET", "/api/sessions/t/messages").reply(emptyTranscript)
        await eventually("transcript lu") { !model.isLoading }
        XCTAssertEqual(model.shownModel, "server-new-model")
        model.draft = "avec le modèle de la liste"
        model.send()
        let run = try await held(3, "POST", "/v1/runs")
        XCTAssertEqual(run.json?["model"] as? String, "server-new-model")
    }

    /// Verdict FAIL @ 7c19673, avec les requêtes HTTP : une liste relue après la confirmation du choix local, qui redonne la valeur d'avant ce choix, reprend la main, et le run suivant porte cette valeur
    func testAReopenedThreadTakesAFreshListThatGivesTheValueFromBeforeALocalChoice() async throws {
        let listed = ListedModel()
        let model = makeModel(bots: profiles(["profil-m", "local-B"]), listedThread: { _, _ in (model: listed.value, read: listed.read) }, startedReads: { listed.read })
        listed.value = "server-A"
        listed.read = 1
        try await openEmptyThread(model, session: "t")
        XCTAssertEqual(model.shownModel, "server-A")
        model.pick(model: "local-B")
        let lock = try await held(1, "POST", "/api/sessions/t/model")
        lock.reply(String(format: lockReply, "local-B"))
        await eventually("modèle confirmé") { model.shownModel == "local-B" }
        model.open(session: "u", of: bot)
        try await held(2, "GET", "/api/sessions/u/messages").reply(emptyTranscript)
        await eventually("transcript lu") { !model.isLoading }

        // la liste est relue après la confirmation : elle redonne server-A
        listed.read = 2
        model.open(session: "t", of: bot)
        try await held(3, "GET", "/api/sessions/t/messages").reply(emptyTranscript)
        await eventually("transcript lu") { !model.isLoading }
        XCTAssertEqual(model.shownModel, "server-A")
        model.draft = "après la relecture"
        model.send()
        let run = try await held(4, "POST", "/v1/runs")
        XCTAssertEqual(run.json?["model"] as? String, "server-A")
    }

    /// Verdict FAIL @ 060716b, consigne Dev Lead du 20/10 à 12:29 : la barre latérale et la conversation de l'app, sur le même faux Hermes
    /// Une relecture de la liste part avant le choix de B et répond server-A après sa confirmation ; sortir puis rouvrir le fil garde B, et le message suivant part avec B
    func testAListReadInFlightDuringAPickDoesNotUndoItAndTheNextMessageLeavesWithThePick() async throws {
        let link = Link(host: hostA, url: "http://host-a.invalid")
        GateProtocol.reset()
        let bots = makeBots(link, profiles: [hostA: [bot]])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GateProtocol.self]
        let model = ConversationModel(
            client: { HermesClient(baseURL: URL(string: link.url)!, configuration: configuration) },
            connection: { link.host },
            listedThread: { bots.listedThread($0, $1) },
            startedReads: { bots.startedReads }
        )
        let list = #"{"data":[{"id":"t","model":"server-A"},{"id":"u"}],"pagination":{"has_more":false}}"#
        bots.toggle(bot)
        try await held(0, "GET", "/p/\(bot)/api/sessions").reply(list)
        await eventually("fils listés") { listed(bots, bot) == ["t", "u"] }
        model.open(session: "t", of: bot)
        try await held(1, "GET", "/api/sessions/t/messages").reply(emptyTranscript)
        await eventually("transcript lu") { !model.isLoading }
        XCTAssertEqual(model.shownModel, "server-A")

        // la relecture part avant le choix et reste en vol pendant sa confirmation
        bots.reload(bot)
        let stale = try await held(2, "GET", "/p/\(bot)/api/sessions")
        model.pick(model: "local-B")
        try await held(3, "POST", "/api/sessions/t/model").reply(String(format: lockReply, "local-B"))
        await eventually("modèle confirmé") { model.shownModel == "local-B" }
        stale.reply(list)
        await eventually("relecture rangée") { bots.listedThread(bot, "t")?.read == 2 }

        model.open(session: "u", of: bot)
        try await held(4, "GET", "/api/sessions/u/messages").reply(emptyTranscript)
        await eventually("transcript lu") { !model.isLoading }
        model.open(session: "t", of: bot)
        try await held(5, "GET", "/api/sessions/t/messages").reply(emptyTranscript)
        await eventually("transcript lu") { !model.isLoading }
        XCTAssertEqual(model.shownModel, "local-B", "la relecture est partie avant le choix : elle ne le défait pas")
        model.draft = "après la réouverture"
        model.send()
        let run = try await held(6, "POST", "/v1/runs")
        XCTAssertEqual(run.json?["model"] as? String, "local-B")
    }

    /// Un choix fait avant que le fil existe se verrouille à la création : le premier tour attend la confirmation et part sur le modèle choisi
    func testTheFirstTurnOfANewThreadWaitsForTheLockOfTheModelPickedBeforeIt() async throws {
        let model = makeModel(bots: profiles(["profil-m", "model-y"]))
        model.select(bot: bot)
        model.pick(model: "model-y")
        XCTAssertEqual(model.shownModel, "model-y", "le choix s'affiche tout de suite")
        XCTAssertFalse(model.isModelPending, "aucune requête n'est partie")
        model.draft = "premier message"
        model.send()
        try await held(0, "POST", "/api/sessions").reply(#"{"session":{"id":"new"}}"#)
        let lock = try await held(1, "POST", "/api/sessions/new/model")
        XCTAssertEqual(lock.json as? [String: String], ["model": "model-y"])
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(GateProtocol.requests.count, 2, "le tour ne part pas avant la confirmation du verrou")
        XCTAssertTrue(model.isModelPending)

        lock.reply(String(format: lockReply, "model-y"))
        let run = try await held(2, "POST", "/v1/runs")
        XCTAssertEqual(run.json?["model"] as? String, "model-y")
        XCTAssertEqual(run.json?["session_id"] as? String, "new")
        XCTAssertEqual(run.json?["input"] as? String, "premier message")
    }

    /// Le verrou refusé après la création abandonne le choix : aucun run ne part, le modèle refusé disparaît, le tour suivant suit le profil
    func testARefusedLockAfterTheCreationDropsTheChoiceAndNoRunUsesIt() async throws {
        let model = makeModel(bots: profiles(["profil-m", "model-y"]))
        model.select(bot: bot)
        model.pick(model: "model-y")
        model.draft = "premier message"
        model.send()
        try await held(0, "POST", "/api/sessions").reply(#"{"session":{"id":"new"}}"#)
        try await held(1, "POST", "/api/sessions/new/model").reply(#"{"error":{"message":"modèle refusé","code":"bad"}}"#, status: 400)
        await eventually("erreur montrée") { model.modelError != nil }
        XCTAssertEqual(model.shownModel, "profil-m", "le modèle refusé n'est plus montré")
        XCTAssertFalse(model.isModelPending)
        XCTAssertFalse(model.isBusy, "le premier tour ne tourne pas")
        XCTAssertNotNil(model.conversation.failure, "l'écran dit que le tour n'est pas parti")

        // la sonde de `set_model` regarde la route ; elle ne démarre aucun tour
        let probe = try await held(2, "POST", "/api/sessions/hd-probe-capabilities/model")
        probe.reply(#"{"error":{"code":"session_not_found","message":"x"}}"#, status: 404)
        await eventually("sonde finie") { model.modelSupport == .available }
        XCTAssertFalse(GateProtocol.requests.contains { $0.request.url?.path.hasSuffix("/v1/runs") == true }, "aucun run n'est parti")

        model.draft = "second message"
        model.send()
        let run = try await held(3, "POST", "/v1/runs")
        XCTAssertNil(run.json?["model"], "le modèle refusé n'est pas réutilisé")
        XCTAssertEqual(run.json?["session_id"] as? String, "new")
    }

    // MARK: changement d'hôte (P1 @ d73d23c)

    private let hostA = "operator@host-a.invalid:22"
    private let hostB = "operator@host-b.invalid:22"

    /// La connexion d'`AppModel` : l'hôte choisi et l'adresse de son API
    /// Changer `host` et `url` est `connect()` vers un autre hôte ; changer `url` seule est la réouverture du tunnel, sur un autre port local
    @MainActor
    private final class Link {
        var host: String
        var url: String

        init(host: String, url: String) {
            self.host = host
            self.url = url
        }
    }

    /// `changed` reçoit chaque bot dont la liste des fils doit se relire
    private func makeModel(_ link: Link, changed: @escaping @MainActor (String) -> Void = { _ in }) -> ConversationModel {
        GateProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GateProtocol.self]
        // un client neuf à chaque appel, comme `AppModel.hermesClient()`
        return ConversationModel(
            client: { HermesClient(baseURL: URL(string: link.url)!, configuration: configuration) },
            connection: { link.host },
            threadsChanged: changed
        )
    }

    private func connect(_ link: Link, to host: String) {
        link.host = host
        link.url = host == hostA ? "http://host-a.invalid" : "http://host-b.invalid"
    }

    private func onA(_ session: String, in model: ConversationModel) -> ConversationMachine.ThreadState? {
        model.machines[hostA]?.threads[ConversationMachine.Key(bot: bot, thread: .session(session))]
    }

    /// Repro 1 du vérificateur : un fil lu sur A, `connect()` vers B, puis Envoyer
    func testAThreadReadOnOneHostSendsNothingToTheNextHostAndComesBackWithItsHost() async throws {
        let link = Link(host: hostA, url: "http://host-a.invalid")
        let model = makeModel(link)
        model.open(session: "on-a", of: bot)
        try await held(0, "GET", "/api/sessions/on-a/messages").reply(transcript((1, "user", "contexte sur A")))
        await eventually("transcript lu") { !model.isLoading }
        model.draft = "suite du fil de A"

        connect(link, to: hostB)
        XCTAssertNil(model.botID, "l'écran quitte les fils de A : la barre latérale montre les bots de B")
        XCTAssertTrue(model.conversation.entries.isEmpty, "rien de A ne s'affiche chez B")
        XCTAssertEqual(model.draft, "", "le brouillon de A ne suit pas chez B")
        model.draft = "brouillon tapé chez B"
        XCTAssertFalse(model.canSend)
        model.send()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(GateProtocol.requests.count, 1, "rien ne part chez B")

        connect(link, to: hostA)
        XCTAssertEqual(model.sessionID, "on-a", "retour sur A : son fil revient")
        XCTAssertEqual(model.conversation.entries.map(\.text), ["contexte sur A"])
        XCTAssertEqual(model.draft, "suite du fil de A", "retour sur A : son brouillon revient, pas celui de B")
        model.send()
        let run = try await held(1, "POST", "/v1/runs")
        XCTAssertEqual(run.request.url?.host, "host-a.invalid")
        XCTAssertEqual(run.json?["session_id"] as? String, "on-a")
        XCTAssertEqual(run.json?["input"] as? String, "suite du fil de A")
    }

    /// Repro 2 du vérificateur : le premier envoi crée son fil sur A, `connect()` vers B, puis la création répond
    /// Le tunnel de A est fermé et son port local peut déjà servir B : le tour ne part pas, le message reste dans son fil avec l'erreur
    func testAFirstSendWhoseThreadIsCreatedAfterAHostSwitchStaysOnItsHostAndSendsNothingMore() async throws {
        let link = Link(host: hostA, url: "http://host-a.invalid")
        var changed: [String] = []
        let model = makeModel(link) { changed.append($0) }
        model.select(bot: bot)
        model.draft = "message privé pour A"
        model.send()
        let creation = try await held(0, "POST", "/api/sessions")
        XCTAssertEqual(creation.request.url?.host, "host-a.invalid")

        connect(link, to: hostB)
        creation.reply(#"{"session":{"id":"on-a"}}"#)
        await eventually("le fil de A garde son message et son erreur") { onA("on-a", in: model)?.conversation.failure != nil }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(GateProtocol.requests.count, 1, "le tour ne part ni chez B ni par l'ancien tunnel")
        let thread = try XCTUnwrap(onA("on-a", in: model))
        XCTAssertEqual(thread.conversation.entries.map(\.text), ["message privé pour A"], "le message n'est pas perdu")
        XCTAssertEqual(thread.conversation.failure, "Hermes n'est pas joignable.")
        XCTAssertEqual(thread.step, .ready)
        XCTAssertEqual(changed, [], "la liste des fils de B ne se relit pas pour un fil de A")
        XCTAssertNil(model.botID)
        XCTAssertTrue(model.conversation.entries.isEmpty, "rien de A ne s'affiche chez B")
    }

    /// Le tunnel se rouvre vers le même hôte sur un autre port local : le fil reste le même et son tour part par la nouvelle adresse
    func testATunnelReopenedToTheSameHostKeepsTheThreadAndSendsThroughTheNewAddress() async throws {
        let link = Link(host: hostA, url: "http://host-a.invalid")
        let model = makeModel(link)
        try await openEmptyThread(model, session: "on-a")
        link.url = "http://tunnel-2.invalid"
        XCTAssertEqual(model.sessionID, "on-a")
        model.draft = "après la réouverture"
        XCTAssertTrue(model.canSend)
        model.send()
        let run = try await held(1, "POST", "/v1/runs")
        XCTAssertEqual(run.request.url?.host, "tunnel-2.invalid")
        XCTAssertEqual(run.json?["session_id"] as? String, "on-a")
    }

    /// Un choix de modèle en vol quand l'hôte change : `set_model` ne part ni chez B ni par l'ancien tunnel, le sélecteur de A se libère avec l'erreur
    func testAPickWhoseHostWasLeftSendsNothingAndFreesTheSelectorOnItsOwnHost() async throws {
        let link = Link(host: hostA, url: "http://host-a.invalid")
        let model = makeModel(link)
        try await openEmptyThread(model, session: "on-a")
        model.pick(model: "model-y")
        connect(link, to: hostB)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(GateProtocol.requests.count, 1, "rien ne part chez B ni par l'ancien tunnel")
        let thread = try XCTUnwrap(onA("on-a", in: model))
        XCTAssertNil(thread.pendingModel)
        XCTAssertNil(thread.model)
        XCTAssertEqual(thread.modelError, "Hermes n'est pas joignable.")
    }

    /// Un bot du même nom chez B ne reprend pas le fil de A : ni son message, ni sa création en vol
    func testTheSameBotOnTheNextHostStartsEmptyAndItsFirstSendGoesToThatHostOnly() async throws {
        let link = Link(host: hostA, url: "http://host-a.invalid")
        let model = makeModel(link)
        model.select(bot: bot)
        model.draft = "pour A"
        model.send()
        let creationA = try await held(0, "POST", "/api/sessions")

        connect(link, to: hostB)
        model.select(bot: bot)
        XCTAssertEqual(model.botID, bot)
        XCTAssertTrue(model.conversation.entries.isEmpty, "le fil de A ne revient pas chez B sous le même nom de bot")
        model.draft = "pour B"
        XCTAssertTrue(model.canSend)
        model.send()
        let creationB = try await held(1, "POST", "/api/sessions")
        XCTAssertEqual(creationB.request.url?.host, "host-b.invalid")
        creationB.reply(#"{"session":{"id":"on-b"}}"#)
        let runB = try await held(2, "POST", "/v1/runs")
        XCTAssertEqual(runB.request.url?.host, "host-b.invalid")
        XCTAssertEqual(runB.json?["input"] as? String, "pour B")
        XCTAssertEqual(runB.json?["session_id"] as? String, "on-b")

        creationA.reply(#"{"session":{"id":"on-a"}}"#)
        await eventually("le fil de A garde son message") { onA("on-a", in: model)?.step == .ready }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(GateProtocol.requests.count, 3, "le message de A ne part pas")
        XCTAssertEqual(model.conversation.entries.map(\.text), ["pour B"])
        XCTAssertEqual(onA("on-a", in: model)?.conversation.entries.map(\.text), ["pour A"])
    }

    // MARK: barre latérale et brouillon au changement d'hôte (P1 @ 1ccb83a)

    /// La barre latérale d'`AppModel` sur le même lien : les profils de chaque hôte, et le même faux Hermes pour les fils
    private func makeBots(_ link: Link, profiles: [String: [String]]) -> BotsModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GateProtocol.self]
        return BotsModel(
            readProfiles: { try ProfileTable.parse(Self.profileTable(profiles[link.host] ?? [])) },
            client: { HermesClient(baseURL: URL(string: link.url)!, configuration: configuration) },
            connection: { link.host }
        )
    }

    /// La sortie de `hermes profile list` avec ces profils actifs
    private nonisolated static func profileTable(_ ids: [String]) -> String {
        (["Profile  Model  Gateway  Alias  Distribution"] + ids.map { "  \($0)   hv-fake-1   running   —   —" }).joined(separator: "\n")
    }

    /// La réponse de `list_sessions` avec ces fils
    private func listing(_ ids: String...) -> String {
        #"{"data":[\#(ids.map { #"{"id":"\#($0)"}"# }.joined(separator: ","))],"pagination":{"has_more":false}}"#
    }

    /// Les fils listés sous un bot dans la barre latérale ; nil tant que la liste n'est pas lue
    private func listed(_ bots: BotsModel, _ id: String) -> [String]? {
        if case .loaded(let sessions) = bots.threads[id] { sessions.map(\.id) } else { nil }
    }

    /// Décision du 20/10 à 09:01 : le parcours A, puis B, puis retour sur A
    /// Aucun fil, aucun bot, aucun brouillon ni aucun identifiant de A ne part chez B ; une réponse tardive de A reste chez A
    func testAFullPathFromAToBAndBackToASendsNoThreadDraftOrIdentifierOfAToB() async throws {
        let link = Link(host: hostA, url: "http://host-a.invalid")
        let model = makeModel(link)
        let bots = makeBots(link, profiles: [hostA: [bot, "bot-de-a"], hostB: [bot]])

        // sur A : la liste, les fils du bot, un fil lu, un brouillon, et les fils d'un autre bot encore en vol
        await bots.refresh()
        bots.toggle(bot)
        try await held(0, "GET", "/p/\(bot)/api/sessions").reply(listing("fil-de-a"))
        await eventually("fils de A listés") { listed(bots, bot) == ["fil-de-a"] }
        model.open(session: "fil-de-a", of: bot)
        try await held(1, "GET", "/api/sessions/fil-de-a/messages").reply(transcript((1, "user", "contexte de A")))
        await eventually("transcript lu") { !model.isLoading }
        model.draft = "brouillon de A"
        bots.toggle("bot-de-a")
        let lateOnA = try await held(2, "GET", "/p/bot-de-a/api/sessions")

        // connect() vers B : avant toute lecture chez B, rien de A ne s'affiche, rien ne se clique et rien ne s'envoie
        connect(link, to: hostB)
        XCTAssertNil(bots.list.shown, "les bots de A ne s'affichent pas chez B")
        XCTAssertTrue(bots.threads.isEmpty, "les fils de A ne s'affichent pas chez B")
        XCTAssertTrue(bots.expanded.isEmpty)
        XCTAssertNil(model.botID)
        XCTAssertNil(model.sessionID)
        XCTAssertEqual(model.draft, "", "le brouillon de A ne suit pas chez B")
        XCTAssertFalse(model.canSend)
        model.send()

        // la réponse tardive de A ne s'affiche pas chez B
        lateOnA.reply(listing("fil-tardif-de-a"))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(bots.threads.isEmpty, "la réponse tardive de A ne s'affiche pas chez B")
        XCTAssertEqual(GateProtocol.requests.count, 3, "rien ne part chez B")

        // sur B : ses bots tout de suite, ses fils, un envoi dans son fil
        await bots.refresh()
        XCTAssertEqual(bots.list.shown?.map(\.id), [bot])
        XCTAssertNil(bots.list.change, "la liste de B s'affiche tout de suite : il n'y a pas de liste de A à comparer")
        bots.toggle(bot)
        try await held(3, "GET", "/p/\(bot)/api/sessions").reply(listing("fil-de-b"))
        await eventually("fils de B listés") { listed(bots, bot) == ["fil-de-b"] }
        model.open(session: "fil-de-b", of: bot)
        try await held(4, "GET", "/api/sessions/fil-de-b/messages").reply(emptyTranscript)
        await eventually("transcript de B lu") { !model.isLoading }
        model.draft = "brouillon de B"
        model.send()
        let runB = try await held(5, "POST", "/v1/runs")
        XCTAssertEqual(runB.request.url?.host, "host-b.invalid")
        XCTAssertEqual(runB.json?["session_id"] as? String, "fil-de-b")
        runB.reply(#"{"error":{"code":"stop","message":"fin du test"}}"#, status: 500)
        await eventually("le tour de B libère son fil") { !model.isBusy }

        // retour sur A : son état revient, rien de B
        connect(link, to: hostA)
        XCTAssertEqual(bots.list.shown?.map(\.id), [bot, "bot-de-a"])
        XCTAssertEqual(listed(bots, bot), ["fil-de-a"])
        XCTAssertEqual(listed(bots, "bot-de-a"), ["fil-tardif-de-a"], "la réponse tardive de A est rangée chez A")
        XCTAssertEqual(model.sessionID, "fil-de-a")
        XCTAssertEqual(model.conversation.entries.map(\.text), ["contexte de A"])
        XCTAssertEqual(model.draft, "brouillon de A", "A retrouve son brouillon, pas celui de B")
        model.send()
        let runA = try await held(6, "POST", "/v1/runs")
        XCTAssertEqual(runA.request.url?.host, "host-a.invalid")
        XCTAssertEqual(runA.json?["session_id"] as? String, "fil-de-a")
        XCTAssertEqual(runA.json?["input"] as? String, "brouillon de A")

        // aucune requête chez B ne porte un fil, un bot, un texte ou un brouillon de A, et inversement
        let ofA = ["fil-de-a", "fil-tardif-de-a", "bot-de-a", "contexte de A", "brouillon de A"]
        let ofB = ["fil-de-b", "brouillon de B"]
        for found in GateProtocol.requests {
            let url = found.request.url?.absoluteString ?? "?"
            let sent = url + " " + String(decoding: found.body, as: UTF8.self)
            for word in found.request.url?.host == "host-b.invalid" ? ofA : ofB {
                XCTAssertFalse(sent.contains(word), "\(url) porte « \(word) »")
            }
        }
    }

    /// Repro du vérificateur @ 1ccb83a : un fil ouvert sur B, un brouillon tapé sur A, puis retour sur B
    /// B retrouve son fil avec son propre brouillon : le texte tapé pour A ne part pas dans le fil de B
    func testADraftTypedOnOneHostIsNotSentInTheThreadOfTheNextHost() async throws {
        let link = Link(host: hostB, url: "http://host-b.invalid")
        let model = makeModel(link)
        try await openEmptyThread(model, session: "fil-de-b")

        connect(link, to: hostA)
        model.select(bot: bot)
        model.draft = "brouillon privé pour A"

        connect(link, to: hostB)
        XCTAssertEqual(model.sessionID, "fil-de-b", "B retrouve son fil")
        XCTAssertEqual(model.draft, "", "B retrouve son brouillon, pas celui de A")
        XCTAssertFalse(model.canSend)
        model.send()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(GateProtocol.requests.count, 1, "le brouillon de A ne part pas chez B")

        connect(link, to: hostA)
        XCTAssertEqual(model.draft, "brouillon privé pour A", "le brouillon reste chez A")
    }

    /// Une liste de bots demandée sur A et arrivée après `connect()` vers B reste chez A
    func testABotListThatArrivesAfterAHostSwitchStaysOnItsHost() async throws {
        let link = Link(host: hostA, url: "http://host-a.invalid")
        let reading = ProfileRead()
        let bots = BotsModel(readProfiles: { await reading.next() }, client: { nil }, connection: { link.host })
        let refresh = Task { await bots.refresh() }
        await eventually("liste des bots de A en vol") { reading.isWaiting }

        connect(link, to: hostB)
        reading.resume(try ProfileTable.parse(Self.profileTable(["bot-de-a"])))
        await refresh.value
        XCTAssertNil(bots.list.shown, "les bots de A ne s'affichent pas chez B")
        XCTAssertEqual(bots.phase, .waiting)

        connect(link, to: hostA)
        XCTAssertEqual(bots.list.shown?.map(\.id), ["bot-de-a"])
        XCTAssertEqual(bots.phase, .ready)
    }

    /// Un bot déplié sur A dont la lecture des fils démarre après `connect()` vers B : rien ne part chez B pour ce bot
    func testThreadsOfABotExpandedOnOneHostAreNeverAskedToTheNextHost() async throws {
        let link = Link(host: hostA, url: "http://host-a.invalid")
        _ = makeModel(link)
        let bots = makeBots(link, profiles: [hostA: ["bot-de-a"]])
        await bots.refresh()
        // le dépli lance la lecture dans une tâche : `connect()` passe avant elle
        bots.toggle("bot-de-a")
        connect(link, to: hostB)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(GateProtocol.requests.count, 0, "les fils d'un bot de A ne se demandent pas à B")

        connect(link, to: hostA)
        XCTAssertEqual(bots.threads["bot-de-a"], .failed("Hermes n'est pas joignable."), "le dépli de A dit pourquoi ses fils manquent : un nouveau dépli les relit")
    }

    /// HD-10 : la barre latérale donne à la conversation ce que la liste des fils dit d'un fil (modèle et numéro de lecture), rien pour un fil d'un autre bot, et un modèle nil pour un fil absent ou sans verrou
    /// Le numéro de lecture monte à chaque lecture, même quand elle redonne les mêmes valeurs ; il est pris au départ de la lecture, et une réponse partie avant celle qui est rangée ne la remplace pas
    func testTheSidebarGivesWhatTheListSaysOfAThreadAndCountsEveryRead() async throws {
        let link = Link(host: hostA, url: "http://host-a.invalid")
        _ = makeModel(link)
        let bots = makeBots(link, profiles: [hostA: [bot, "bot-de-a"]])
        await bots.refresh()
        XCTAssertNil(bots.listedThread(bot, "t"), "la liste n'est pas lue")
        bots.toggle(bot)
        let list = #"{"data":[{"id":"t","model":"hv-fake-2"},{"id":"u","model":null},{"id":"v"}],"pagination":{"has_more":false}}"#
        try await held(0, "GET", "/p/\(bot)/api/sessions").reply(list)
        await eventually("fils listés") { listed(bots, bot) == ["t", "u", "v"] }
        XCTAssertEqual(bots.listedThread(bot, "t")?.model, "hv-fake-2")
        XCTAssertEqual(bots.listedThread(bot, "t")?.read, 1)
        XCTAssertNotNil(bots.listedThread(bot, "u"))
        XCTAssertNil(bots.listedThread(bot, "u")?.model)
        XCTAssertNil(bots.listedThread(bot, "v")?.model)
        XCTAssertNil(bots.listedThread(bot, "absent")?.model, "un fil absent de la liste n'a pas de modèle")
        XCTAssertEqual(bots.listedThread(bot, "absent")?.read, 1, "mais la liste a bien été lue")
        XCTAssertNil(bots.listedThread("bot-de-a", "t"), "la liste d'un autre bot n'est pas lue")

        bots.reload(bot)
        try await held(1, "GET", "/p/\(bot)/api/sessions").reply(list)
        await eventually("seconde lecture") { bots.listedThread(bot, "t")?.read == 2 }
        XCTAssertEqual(bots.listedThread(bot, "t")?.model, "hv-fake-2", "les mêmes valeurs, une lecture de plus")

        // deux relectures en vol : la plus récente répond d'abord
        bots.reload(bot)
        let older = try await held(2, "GET", "/p/\(bot)/api/sessions")
        XCTAssertEqual(bots.startedReads, 3, "la lecture 3 a pris son numéro en partant")
        XCTAssertEqual(bots.listedThread(bot, "t")?.read, 2, "elle n'a pas encore répondu")
        bots.reload(bot)
        try await held(3, "GET", "/p/\(bot)/api/sessions").reply(#"{"data":[{"id":"t","model":"server-new"}],"pagination":{"has_more":false}}"#)
        await eventually("lecture 4 rangée") { bots.listedThread(bot, "t")?.read == 4 }
        older.reply(list)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(bots.listedThread(bot, "t")?.read, 4, "la lecture 3, partie avant la 4, ne la remplace pas")
        XCTAssertEqual(bots.listedThread(bot, "t")?.model, "server-new")
    }

    func testALateUnauthorizedListSessionsDoesNotReplaceReloadedThreads() async throws {
        let link = Link(host: hostA, url: "http://host-a.invalid")
        _ = makeModel(link)
        let bots = makeBots(link, profiles: [hostA: [bot]])
        await bots.refresh()
        bots.toggle(bot)
        try await held(0, "GET", "/p/\(bot)/api/sessions").reply(listing("fil-1"))
        await eventually("fils listés") { listed(bots, bot) == ["fil-1"] }

        bots.reload(bot)
        let older = try await held(1, "GET", "/p/\(bot)/api/sessions")
        bots.reload(bot)
        try await held(2, "GET", "/p/\(bot)/api/sessions").reply(listing("fil-1", "fil-2"))
        await eventually("fils rechargés") { listed(bots, bot) == ["fil-1", "fil-2"] }

        older.reply(#"{"error":{"message":"Invalid gateway API key"}}"#, status: 401)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(listed(bots, bot), ["fil-1", "fil-2"], "le 401 de la lecture précédente ne remplace pas les fils rechargés")
    }

    private enum Operation: String, CaseIterable {
        case load, create, firstSend, startRun, stream, reread
    }

    /// Chaque opération en vol croisée avec un changement d'hôte : son résultat arrive dans son fil sur A, et rien ne part ensuite, ni chez B ni par l'ancien tunnel
    func testAHostSwitchDuringEachOperationKeepsItsResultOnItsHostAndSendsNothingAfterIt() async throws {
        for operation in Operation.allCases { try await check(operation) }
    }

    private func check(_ operation: Operation) async throws {
        let label = operation.rawValue
        let link = Link(host: hostA, url: "http://host-a.invalid")
        var changed: [String] = []
        let model = makeModel(link) { changed.append($0) }
        // l'opération en vol sur A, sa réponse, le fil où elle arrive et ce qu'on doit y lire
        let pending: GateProtocol
        let reply: String
        let origin: String
        let landed: (ConversationMachine.ThreadState) -> Bool
        switch operation {
        case .load:
            model.open(session: "t", of: bot)
            pending = try await held(0, "GET", "/api/sessions/t/messages")
            reply = transcript((1, "user", "question"), (2, "assistant", "réponse"))
            origin = "t"
            landed = { $0.conversation.entries.map(\.text) == ["question", "réponse"] }
        case .create:
            try await openEmptyThread(model, session: "t")
            model.newSession()
            pending = try await held(1, "POST", "/api/sessions")
            reply = #"{"session":{"id":"créé"}}"#
            origin = "créé"
            landed = { $0.conversation.entries.isEmpty && $0.conversation.failure == nil }
        case .firstSend:
            model.select(bot: bot)
            model.draft = "message"
            model.send()
            pending = try await held(0, "POST", "/api/sessions")
            reply = #"{"session":{"id":"créé"}}"#
            origin = "créé"
            landed = { $0.conversation.entries.map(\.text) == ["message"] && $0.conversation.failure == "Hermes n'est pas joignable." }
        case .startRun:
            try await openEmptyThread(model, session: "t")
            model.draft = "message"
            model.send()
            pending = try await held(1, "POST", "/v1/runs")
            reply = #"{"run_id":"r1"}"#
            origin = "t"
            landed = { $0.conversation.entries.map(\.text) == ["message"] && $0.conversation.failure == "Hermes n'est pas joignable." }
        case .stream:
            try await openEmptyThread(model, session: "t")
            model.draft = "message"
            model.send()
            try await held(1, "POST", "/v1/runs").reply(#"{"run_id":"r1"}"#)
            pending = try await held(2, "GET", "/v1/runs/r1/events")
            reply = completedTurn("réponse")
            origin = "t"
            landed = { $0.conversation.entries.map(\.text) == ["message", "réponse"] && $0.conversation.end == .completed }
        case .reread:
            try await openEmptyThread(model, session: "t")
            model.draft = "message"
            model.send()
            try await held(1, "POST", "/v1/runs").reply(#"{"run_id":"r1"}"#)
            try await held(2, "GET", "/v1/runs/r1/events").reply(completedTurn("réponse"))
            pending = try await held(3, "GET", "/api/sessions/t/messages")
            reply = transcript((1, "user", "message"), (2, "assistant", "réponse"))
            origin = "t"
            landed = { $0.conversation.entries.compactMap(\.serverIndex) == [1, 2] && $0.conversation.end == .completed }
        }
        let sent = GateProtocol.requests.count
        let relisted = changed

        connect(link, to: hostB)
        pending.reply(reply)
        await eventually("\(label) : le résultat arrive dans son fil sur A") { onA(origin, in: model).map { $0.step == .ready && landed($0) } ?? false }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(GateProtocol.requests.count, sent, "\(label) : une requête est partie après le changement d'hôte")
        XCTAssertEqual(changed, relisted, "\(label) : la liste des fils de B se relit pour un fil de A")
        XCTAssertNil(model.botID, "\(label) : le résultat ramène un fil de A à l'écran chez B")
        XCTAssertTrue(model.conversation.entries.isEmpty, label)
    }

    // MARK: l'outil en cours et les approbations (HD-11)

    private let toolStarted = #"data: {"event":"tool.started","tool":"file.write","preview":"/tmp/hv.txt"}"# + "\n\n"
    private let approvalRequest = #"data: {"event":"approval.request","request_id":"apr","command":"/tmp/hv.txt","description":"écrire le fichier","choices":["once","deny"]}"# + "\n\n"
    private let approvalOK = #"{"object":"hermes.run.approval_response","run_id":"r1","choice":"once","request_id":"apr","resolved":1}"#
    private let availableProbe = #"{"error":{"code":"run_not_found","message":"x"}}"#

    /// Les POST de décision de ce run, sans la sonde de la route
    private func approvalPosts() -> [GateProtocol] {
        GateProtocol.requests.filter { $0.request.httpMethod == "POST" && $0.request.url?.path.hasSuffix("/v1/runs/r1/approval") == true }
    }

    private func probes() -> [GateProtocol] {
        GateProtocol.requests.filter { $0.request.url?.path.hasSuffix("/v1/runs/hd-probe-capabilities/approval") == true }
    }

    /// Un tour parti qui a lancé `file.write` puis demandé une approbation : le flux reste ouvert, la route répond à la sonde (`probe`)
    private func turnWaitingForApproval(_ model: ConversationModel, probe: (status: Int, body: String)? = (404, #"{"error":{"code":"run_not_found","message":"x"}}"#)) async throws -> GateProtocol {
        try await openEmptyThread(model, session: "t")
        model.draft = "go"
        model.send()
        try await heldRequest("POST", "/v1/runs").reply(#"{"run_id":"r1"}"#)
        let events = try await heldRequest("GET", "/v1/runs/r1/events")
        events.open()
        events.send(toolStarted + approvalRequest)
        await eventually("la demande est à l'écran") { model.approval != nil }
        if let probe {
            try await heldRequest("POST", "/v1/runs/hd-probe-capabilities/approval").reply(probe.body, status: probe.status)
            await eventually("la sonde a répondu") { model.approveSupport != .unknown }
        }
        return events
    }

    /// Finit le flux du tour, puis répond à la relecture du fil que l'app fait à la fin du tour : sans réponse, la requête resterait en vol dans le test suivant
    private func finishTurn(_ events: GateProtocol, with stream: String) async throws {
        events.send(stream + ": stream closed\n\n")
        events.finish()
        let reads = { GateProtocol.requests.filter { $0.request.httpMethod == "GET" && $0.request.url?.path.hasSuffix("/api/sessions/t/messages") == true } }
        await eventually("la relecture du fil") { reads().count >= 2 }
        reads().last?.reply(emptyTranscript)
    }

    private let afterApproval = #"data: {"event":"approval.responded","choice":"once","request_id":"apr","resolved":1}"# + "\n\n"
        + #"data: {"event":"tool.completed","tool":"file.write","duration":0.1,"error":false}"# + "\n\n"
        + #"data: {"event":"run.completed","output":"fini"}"# + "\n\n"

    func testTheCurrentToolShowsWhileItRunsAndClearsWhenItIsCompleted() async throws {
        let model = makeModel()
        try await openEmptyThread(model, session: "t")
        XCTAssertNil(model.currentTool)
        model.draft = "go"
        model.send()
        try await heldRequest("POST", "/v1/runs").reply(#"{"run_id":"r1"}"#)
        let events = try await heldRequest("GET", "/v1/runs/r1/events")
        events.open()
        events.send(toolStarted)
        await eventually("l'outil est en cours") { model.currentTool == "file.write" }
        XCTAssertNil(model.approval)
        try await finishTurn(events, with: #"data: {"event":"tool.completed","tool":"file.write","duration":0.1,"error":false}"# + "\n\n" + #"data: {"event":"run.completed","output":"fini"}"# + "\n\n")
        await eventually("le tour est fini") { model.conversation.end == .completed }
        XCTAssertNil(model.currentTool)
    }

    func testAnApprovalShowsTheToolAndTheParametersThenOneAnswerGoesOutAndTheTurnGoesOn() async throws {
        let model = makeModel()
        let events = try await turnWaitingForApproval(model)
        let request = try XCTUnwrap(model.approval?.request)
        XCTAssertEqual(request.tool, "file.write")
        XCTAssertEqual(request.command, "/tmp/hv.txt")
        XCTAssertEqual(model.currentTool, "file.write")
        XCTAssertTrue(model.isBusy, "le tour attend l'utilisateur")
        XCTAssertEqual(model.approveSupport, .available)
        XCTAssertTrue(approvalPosts().isEmpty, "rien ne part avant la réponse de l'utilisateur")

        model.answer(.yes)
        model.answer(.yes)
        let post = try await heldRequest("POST", "/v1/runs/r1/approval")
        XCTAssertEqual(post.request.url?.path, "/p/\(bot)/v1/runs/r1/approval")
        XCTAssertEqual(post.json?["choice"] as? String, "once")
        XCTAssertEqual(post.json?["request_id"] as? String, "apr")
        post.reply(approvalOK)
        await eventually("la feuille se ferme") { model.approval == nil }
        try await finishTurn(events, with: afterApproval)
        await eventually("le tour est fini") { model.conversation.end == .completed }
        XCTAssertEqual(approvalPosts().count, 1, "un double clic n'envoie qu'une décision")
        XCTAssertEqual(probes().count, 1)
        XCTAssertNil(model.currentTool)
    }

    func testARefusalGoesOutAsDeny() async throws {
        let model = makeModel()
        let events = try await turnWaitingForApproval(model)
        model.answer(.no)
        let post = try await heldRequest("POST", "/v1/runs/r1/approval")
        XCTAssertEqual(post.json?["choice"] as? String, "deny")
        post.reply(approvalOK)
        await eventually("la feuille se ferme") { model.approval == nil }
        try await finishTurn(events, with: afterApproval)
        await eventually("le tour est fini") { model.conversation.end != nil }
    }

    func testADecisionThatCannotGoOutStaysOnScreenAndGoesOutOnceWhenTheLinkReturns() async throws {
        let model = makeModel()
        let events = try await turnWaitingForApproval(model)
        model.answer(.yes)
        try await heldRequest("POST", "/v1/runs/r1/approval").reply(#"{"error":"unavailable"}"#, status: 503)
        await eventually("la décision attend la liaison") { model.approval?.isQueued == true }
        XCTAssertEqual(model.approval?.decision, .yes, "la décision est gardée")
        XCTAssertTrue(model.isBusy)
        // la liaison revient : la décision repart, la même
        await eventually("la décision repart") { approvalPosts().count >= 2 }
        XCTAssertEqual(approvalPosts()[1].json?["choice"] as? String, "once")
        XCTAssertEqual(approvalPosts()[1].json?["request_id"] as? String, "apr")
        approvalPosts()[1].reply(approvalOK)
        await eventually("la feuille se ferme") { model.approval == nil }
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(approvalPosts().count, 2, "prise une fois, la décision ne repart plus")
        try await finishTurn(events, with: afterApproval)
        await eventually("le tour est fini") { model.conversation.end == .completed }
    }

    func testATransportFailureQueuesTheDecisionThenSendsItAgain() async throws {
        // une panne de transport (liaison coupée) n'est pas un refus de Hermes : la décision attend
        let model = makeModel()
        let events = try await turnWaitingForApproval(model)
        model.answer(.no)
        let first = try await heldRequest("POST", "/v1/runs/r1/approval")
        first.fail(URLError(.notConnectedToInternet))
        await eventually("la décision attend la liaison") { model.approval?.isQueued == true }
        await eventually("la décision repart") { approvalPosts().count == 2 }
        approvalPosts()[1].reply(approvalOK)
        await eventually("la feuille se ferme") { model.approval == nil }
        try await finishTurn(events, with: afterApproval)
        await eventually("le tour est fini") { model.conversation.end == .completed }
    }

    func testARefusalOfTheDecisionByHermesShowsItAndLetsTheUserAnswerAgain() async throws {
        let model = makeModel()
        let events = try await turnWaitingForApproval(model)
        model.answer(.yes)
        try await heldRequest("POST", "/v1/runs/r1/approval").reply(#"{"error":{"code":"run_not_found","message":"x"}}"#, status: 404)
        await eventually("le refus est montré") { model.approval?.error != nil }
        XCTAssertNil(model.approval?.decision, "l'utilisateur peut répondre de nouveau")
        XCTAssertEqual(model.approval?.isQueued, false)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(approvalPosts().count, 1, "un refus de Hermes ne se renvoie pas seul")
        model.answer(.yes)
        await eventually("la seconde décision part") { approvalPosts().count == 2 }
        approvalPosts()[1].reply(approvalOK)
        await eventually("la feuille se ferme") { model.approval == nil }
        try await finishTurn(events, with: afterApproval)
    }

    func testAnEndedTurnStopsTheRetryOfAQueuedDecision() async throws {
        let model = makeModel()
        let events = try await turnWaitingForApproval(model)
        model.answer(.yes)
        try await heldRequest("POST", "/v1/runs/r1/approval").reply("", status: 503)
        await eventually("la décision attend la liaison") { model.approval?.isQueued == true }
        await eventually("un essai de plus") { approvalPosts().count == 2 }
        // Hermes a refusé de lui-même (délai) et le tour a fini : plus rien à répondre
        try await finishTurn(events, with: #"data: {"event":"approval.responded","choice":"deny","request_id":"apr","resolved":1}"# + "\n\n" + #"data: {"event":"run.failed","error":"timeout"}"# + "\n\n")
        await eventually("le tour est fini") { model.conversation.end == .failed }
        XCTAssertNil(model.approval)
        approvalPosts()[1].reply("", status: 503)
        let count = approvalPosts().count
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(approvalPosts().count, count, "aucun essai après la fin du tour")
    }

    func testARouteHermesDroppedShowsTheRequestWithTheDisabledMessageAndSendsNothing() async throws {
        let model = makeModel()
        let events = try await turnWaitingForApproval(model, probe: (404, #"{"error":"404: Not Found"}"#))
        await eventually("la sonde a répondu") { model.approveSupport != .unknown }
        XCTAssertEqual(model.approveSupport, .disabled(message: "Fonction désactivée (la réponse à une approbation) : Hermes ne propose plus cette route."))
        XCTAssertEqual(model.approval?.request.command, "/tmp/hv.txt", "la demande reste affichée")
        model.answer(.yes)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(approvalPosts().isEmpty, "une route retirée ne reçoit rien")
        XCTAssertNil(model.approval?.decision)
        events.finish()
        let replay = try await held(4, "GET", "/v1/runs/r1/events")
        XCTAssertTrue(model.isBusy)
        XCTAssertEqual(model.approval?.request.command, "/tmp/hv.txt")
        XCTAssertTrue(approvalPosts().isEmpty)
        replay.open()
        try await finishTurn(replay, with: afterApproval)
        XCTAssertEqual(model.conversation.end, .completed)
        XCTAssertNil(model.approval)
    }

    func testTheApprovalOfAThreadOffScreenIsNotShownAndWaitsForTheUser() async throws {
        let model = makeModel()
        let events = try await turnWaitingForApproval(model)
        model.open(session: "u", of: bot)
        try await heldRequest("GET", "/api/sessions/u/messages").reply(emptyTranscript)
        await eventually("transcript lu") { !model.isLoading }
        XCTAssertNil(model.approval)
        model.answer(.yes)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(approvalPosts().isEmpty)
        model.open(session: "t", of: bot)
        XCTAssertEqual(model.approval?.request.command, "/tmp/hv.txt")
        events.finish()
        let replay = try await held(5, "GET", "/v1/runs/r1/events")
        XCTAssertTrue(model.isBusy)
        XCTAssertEqual(model.approval?.request.command, "/tmp/hv.txt")
        XCTAssertTrue(approvalPosts().isEmpty)
        replay.open()
        try await finishTurn(replay, with: afterApproval)
        XCTAssertEqual(model.conversation.end, .completed)
        XCTAssertNil(model.approval)
    }
}

/// Une lecture de `hermes profile list` qui attend que le test lui donne sa réponse
@MainActor
private final class ProfileRead {
    private var waiting: CheckedContinuation<[Profile], Never>?

    var isWaiting: Bool { waiting != nil }

    func next() async -> [Profile] { await withCheckedContinuation { waiting = $0 } }

    func resume(_ profiles: [Profile]) {
        waiting?.resume(returning: profiles)
        waiting = nil
    }
}

/// Un faux Hermes : chaque requête reste en attente jusqu'à ce que le test y réponde
private final class GateProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var held: [GateProtocol] = []

    static var requests: [GateProtocol] { lock.withLock { held } }
    static func reset() { lock.withLock { held = [] } }

    private var received = Data()
    private var stopped = false

    var body: Data { Self.lock.withLock { received } }
    var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer[0..<count])
            }
            stream.close()
        }
        Self.lock.withLock {
            received = data
            Self.held.append(self)
        }
    }

    override func stopLoading() { Self.lock.withLock { stopped = true } }

    /// Sans effet quand l'app a déjà annulé la requête
    func reply(_ text: String, status: Int = 200) {
        begin(status: status, headers: nil)
        send(text)
        finish()
    }

    /// Un flux d'événements dont la suite n'est pas encore là : `open`, puis `send` à mesure, puis `finish`
    /// Le type `text/event-stream` est celui de Hermes : sans lui, URLSession garde les premiers octets pour deviner le type, et le flux n'arrive qu'à sa fin
    func open(status: Int = 200) {
        begin(status: status, headers: ["Content-Type": "text/event-stream"])
    }

    private func begin(status: Int, headers: [String: String]?) {
        guard !Self.lock.withLock({ stopped }), let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    func send(_ text: String) {
        guard !Self.lock.withLock({ stopped }) else { return }
        client?.urlProtocol(self, didLoad: Data(text.utf8))
    }

    func finish() {
        guard !Self.lock.withLock({ stopped }) else { return }
        client?.urlProtocolDidFinishLoading(self)
    }

    /// Une panne de transport, comme une liaison coupée
    func fail(_ error: URLError) {
        guard !Self.lock.withLock({ stopped }) else { return }
        client?.urlProtocol(self, didFailWithError: error)
    }
}
