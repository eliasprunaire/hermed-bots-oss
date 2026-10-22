import HermesAdapter
import XCTest

// compilé dans le paquet de tests lui-même, sans l'app comme hôte : la machine d'états seule, sans réseau
final class ConversationMachineTests: XCTestCase {
    private typealias Key = ConversationMachine.Key
    private let a = "bot-a"
    private let b = "bot-b"

    private func key(_ bot: String, _ session: String) -> Key { Key(bot: bot, thread: .session(session)) }

    // MARK: transitions, une par ligne du tableau

    func testWithoutABotNothingCanBeSent() {
        var h = Harness()
        XCTAssertNil(h.machine.screen)
        XCTAssertFalse(h.machine.canSend("bonjour"))
        XCTAssertEqual(h.apply(.send("bonjour")), [])
        XCTAssertEqual(h.apply(.newSession), [], "« Nouvelle session » exige un bot")
    }

    func testSelectingABotShowsAThreadNotYetCreatedThatAcceptsASend() {
        var h = Harness()
        XCTAssertEqual(h.apply(.select(bot: a)), [], "choisir un bot ne demande rien à Hermes")
        XCTAssertEqual(h.machine.screen?.bot, a)
        XCTAssertNil(h.machine.screen?.session)
        XCTAssertEqual(h.machine.shown.step, .ready)
        XCTAssertTrue(h.machine.canSend("bonjour"))
        XCTAssertFalse(h.machine.canSend("   \n"), "un brouillon fait de blancs ne part pas")
    }

    func testOpeningAThreadReadsItsTranscriptAndRefusesASendMeanwhile() throws {
        var h = Harness()
        let load = try XCTUnwrap(h.apply(.open(session: "t", bot: a)).first)
        XCTAssertEqual(load, .load(key(a, "t")))
        XCTAssertEqual(h.machine.shown.step, .loading)
        XCTAssertFalse(h.machine.canSend("bonjour"))
        h.resolve(load)
        XCTAssertEqual(h.machine.shown.step, .ready)
        XCTAssertEqual(h.machine.shown.conversation.entries.map(\.serverIndex), [1, 2])
        XCTAssertTrue(h.machine.canSend("bonjour"))
    }

    func testTheFirstSendCreatesTheThreadThenStartsTheTurnThereAndReadsItAgain() throws {
        var h = Harness()
        h.apply(.select(bot: a))
        let unsaved = try XCTUnwrap(h.machine.screen)
        let creation = try XCTUnwrap(h.apply(.send("  bonjour ")).first)
        XCTAssertEqual(creation, .create(unsaved, message: "bonjour"))
        XCTAssertEqual(h.machine.shown.step, .sending)
        XCTAssertEqual(h.machine.shown.conversation.entries.map(\.text), ["bonjour"])
        XCTAssertFalse(h.machine.canSend("encore"))

        let run = try XCTUnwrap(h.resolve(creation).first)
        XCTAssertEqual(run, .run(key(a, "créé-1"), message: "bonjour"))
        XCTAssertEqual(h.machine.screen, key(a, "créé-1"), "l'écran suit le fil créé")
        XCTAssertNil(h.machine.threads[unsaved], "le fil pas encore créé est devenu le fil créé")
        XCTAssertEqual(h.threadsChanged, [a], "la liste des fils du bot se relit à la création")

        let reread = try XCTUnwrap(h.resolve(run).first)
        XCTAssertEqual(reread, .reread(key(a, "créé-1"), turn: 1))
        XCTAssertEqual(h.machine.shown.conversation.end, .completed)
        XCTAssertEqual(h.machine.shown.conversation.entries.map(\.text), ["bonjour", "réponse"])
        XCTAssertEqual(h.threadsChanged, [a, a], "et à la fin du tour")
        h.resolve(reread)
        XCTAssertEqual(h.machine.shown.conversation.entries.map(\.serverIndex), [100, 101])
        XCTAssertTrue(h.machine.canSend("suite"))
    }

    func testASendInAThreadThatExistsStartsTheTurnInIt() throws {
        var h = Harness()
        h.apply(.open(session: "t", bot: a))
        h.resolveAll()
        XCTAssertEqual(h.apply(.send("bonjour")), [.run(key(a, "t"), message: "bonjour")])
    }

    func testADoubleSendStartsOneTurn() {
        var h = Harness()
        h.apply(.select(bot: a))
        XCTAssertEqual(h.apply(.send("bonjour")).count, 1)
        XCTAssertEqual(h.apply(.send("bonjour")), [], "le second appel d'un double clic trouve le tour ouvert")
        XCTAssertEqual(h.machine.shown.conversation.entries.count, 1)
    }

    func testTheReplyGrowsOnScreenAsItStreams() throws {
        var h = Harness()
        h.apply(.open(session: "t", bot: a))
        h.resolveAll()
        h.apply(.send("bonjour"))
        h.apply(.streamed(key(a, "t"), "Bon"))
        XCTAssertEqual(h.machine.shown.conversation.entries.last?.text, "Bon")
        h.apply(.streamed(key(a, "t"), "Bonjour à vous"))
        XCTAssertEqual(h.machine.shown.conversation.entries.last?.text, "Bonjour à vous")
        XCTAssertEqual(h.machine.shown.step, .sending)
    }

    func testAStreamThatStopsWithoutATerminalStateIsAFailureNotAnInventedEnd() {
        var h = Harness()
        h.apply(.open(session: "t", bot: a))
        h.resolveAll()
        h.apply(.send("bonjour"))
        XCTAssertEqual(h.apply(.ended(key(a, "t"), reply: "début", end: nil, detail: nil)), [.reread(key(a, "t"), turn: 1)])
        XCTAssertNil(h.machine.shown.conversation.end)
        XCTAssertNotNil(h.machine.shown.conversation.failure)
        XCTAssertEqual(h.machine.shown.step, .ready)
    }

    func testNewSessionShowsAnEmptyThreadThatRefusesASendUntilHermesCreatesIt() throws {
        var h = Harness()
        h.apply(.open(session: "old", bot: a))
        h.resolveAll()
        let creation = try XCTUnwrap(h.apply(.newSession).first)
        XCTAssertEqual(creation, .create(try XCTUnwrap(h.machine.screen), message: nil))
        XCTAssertNil(h.machine.screen?.session)
        XCTAssertEqual(h.machine.shown.step, .creating)
        XCTAssertTrue(h.machine.shown.conversation.entries.isEmpty)
        XCTAssertFalse(h.machine.canSend("bonjour"))
        XCTAssertEqual(h.resolve(creation), [], "« Nouvelle session » n'envoie aucun message")
        XCTAssertEqual(h.machine.screen, key(a, "créé-1"))
        XCTAssertEqual(h.machine.shown.step, .ready)
        XCTAssertTrue(h.machine.canSend("bonjour"))
        XCTAssertEqual(h.threadsChanged, [a])
        XCTAssertEqual(h.machine.threads[key(a, "old")]?.conversation.entries.count, 2, "l'ancien fil reste tel quel")
    }

    func testADoubleClickOnNewSessionCreatesOneThread() {
        var h = Harness()
        h.apply(.open(session: "old", bot: a))
        h.resolveAll()
        XCTAssertEqual(h.apply(.newSession).count, 1)
        XCTAssertEqual(h.apply(.newSession), [], "le second clic trouve la création en cours")
        XCTAssertEqual(h.machine.threads.keys.filter { $0.session == nil }.count, 1)
        XCTAssertEqual(h.machine.shown.step, .creating)
    }

    func testEachFailureStaysOnItsThreadAndFreesIt() throws {
        for step in ["lecture", "création", "tour"] {
            var h = Harness()
            switch step {
            case "lecture": h.apply(.open(session: "t", bot: a))
            case "création": h.apply(.select(bot: a)); h.apply(.newSession)
            default: h.apply(.open(session: "t", bot: a)); h.resolveAll(); h.apply(.send("bonjour"))
            }
            let origin = try XCTUnwrap(h.machine.screen)
            let effect = try XCTUnwrap(h.inFlight.first)
            h.resolve(effect, succeeds: false)
            XCTAssertEqual(h.machine.threads[origin]?.step, .ready, step)
            XCTAssertNotNil(h.machine.threads[origin]?.conversation.failure, step)
            XCTAssertTrue(h.machine.canSend("encore"), "\(step) : le fil n'est pas bloqué")
        }
    }

    func testAResultForAThreadThatIsNotWaitingForItChangesNothing() {
        var h = Harness()
        h.apply(.open(session: "t", bot: a))
        h.resolveAll()
        let t = key(a, "t")
        let before = h.machine
        XCTAssertEqual(h.apply(.loaded(t, [(9, .user, "périmé")])), [])
        XCTAssertEqual(h.apply(.streamed(t, "périmé")), [])
        XCTAssertEqual(h.apply(.ended(t, reply: "périmé", end: .completed, detail: nil)), [])
        XCTAssertEqual(h.apply(.reread(t, turn: 7, [(9, .user, "périmé")])), [])
        XCTAssertEqual(h.apply(.failed(t, "périmé")), [])
        XCTAssertEqual(h.apply(.created(t, session: "périmé", message: nil)), [])
        XCTAssertEqual(h.apply(.loaded(key(b, "inconnu"), [(9, .user, "périmé")])), [])
        XCTAssertEqual(h.machine, before)
    }

    func testTheReadAgainOfATurnIsStaleOnceTheNextTurnStarts() throws {
        var h = Harness()
        h.apply(.open(session: "t", bot: a))
        h.resolveAll()
        let run = try XCTUnwrap(h.apply(.send("premier")).first)
        XCTAssertEqual(h.resolve(run), [.reread(key(a, "t"), turn: 1)])
        let second = try XCTUnwrap(h.apply(.send("second")).first)
        XCTAssertEqual(h.apply(.reread(key(a, "t"), turn: 1, [(1, .user, "question de t")])), [], "la relecture du premier tour arrive après le second envoi")
        XCTAssertEqual(h.machine.shown.conversation.entries.map(\.text).suffix(3), ["premier", "réponse", "second"])
        XCTAssertEqual(h.machine.shown.step, .sending)
        h.resolve(second)
        XCTAssertEqual(h.machine.shown.conversation.entries.map(\.text).suffix(2), ["second", "réponse"])
    }

    func testLeavingAThreadNotYetCreatedWithNothingInItForgetsIt() {
        var h = Harness()
        h.apply(.select(bot: a))
        h.apply(.select(bot: b))
        XCTAssertEqual(h.machine.threads.keys.map(\.bot), [b])
        h.apply(.open(session: "t", bot: b))
        XCTAssertEqual(Set(h.machine.threads.keys), [key(b, "t")])
    }

    func testSelectingTheShownBotAgainKeepsTheShownThread() {
        var h = Harness()
        h.apply(.open(session: "t", bot: a))
        h.resolveAll()
        XCTAssertEqual(h.apply(.select(bot: a)), [])
        XCTAssertEqual(h.machine.screen, key(a, "t"))
    }

    // MARK: les cinq cas relevés par le vérificateur et le Dev Lead

    /// Cas 1 : un envoi pendant la création d'une session
    func testASendDuringTheCreationOfANewSessionIsRefusedThenGoesToTheCreatedThread() throws {
        var h = Harness()
        h.apply(.open(session: "old", bot: a))
        h.resolveAll()
        let creation = try XCTUnwrap(h.apply(.newSession).first)
        XCTAssertFalse(h.machine.canSend("pour le nouveau fil"))
        XCTAssertEqual(h.apply(.send("pour le nouveau fil")), [], "rien ne part pendant la création")
        XCTAssertTrue(h.machine.shown.conversation.entries.isEmpty)
        h.resolve(creation)
        XCTAssertEqual(h.apply(.send("pour le nouveau fil")), [.run(key(a, "créé-1"), message: "pour le nouveau fil")])
        XCTAssertEqual(h.machine.threads[key(a, "old")]?.conversation.entries.count, 2, "l'ancien fil garde son transcript")
    }

    /// Cas 2 : la réouverture du fil actif
    func testReopeningTheThreadWhoseTurnRunsKeepsTheTurnAndRefusesASecondOne() throws {
        var h = Harness()
        h.apply(.open(session: "t", bot: a))
        h.resolveAll()
        let run = try XCTUnwrap(h.apply(.send("premier")).first)
        XCTAssertEqual(h.apply(.open(session: "t", bot: a)), [], "le tour est en vol : rien à relire, rien à relancer")
        XCTAssertEqual(h.machine.shown.step, .sending)
        XCTAssertEqual(h.machine.shown.conversation.entries.last?.text, "premier")
        XCTAssertFalse(h.machine.canSend("second"))
        XCTAssertEqual(h.apply(.send("second")), [])
        h.apply(.streamed(key(a, "t"), "rép"))
        XCTAssertEqual(h.machine.shown.conversation.entries.last?.text, "rép", "la réponse arrive dans le fil rouvert")
        h.resolve(run)
        XCTAssertTrue(h.machine.canSend("second"))
    }

    /// Cas 3 : un changement de bot pendant la création du premier fil (FAIL @ d9ce2b20)
    func testSwitchingBotWhileTheFirstSendCreatesItsThreadKeepsTheMessageInThatThread() throws {
        var h = Harness()
        h.apply(.select(bot: a))
        let creation = try XCTUnwrap(h.apply(.send("premier message")).first)
        h.apply(.select(bot: b))
        let run = try XCTUnwrap(h.resolve(creation).first)
        XCTAssertEqual(run, .run(key(a, "créé-1"), message: "premier message"), "le message part dans le fil créé pour lui, chez son bot")
        XCTAssertEqual(h.machine.screen?.bot, b)
        XCTAssertTrue(h.machine.shown.conversation.entries.isEmpty)
        XCTAssertEqual(h.resolve(run), [], "aucune relecture d'un fil qui n'est pas à l'écran")
        XCTAssertTrue(h.machine.shown.conversation.entries.isEmpty, "la fin du tour reste dans son fil")
        XCTAssertEqual(h.machine.threads[key(a, "créé-1")]?.conversation.end, .completed)

        let load = try XCTUnwrap(h.apply(.open(session: "créé-1", bot: a)).first)
        h.resolve(load)
        XCTAssertEqual(h.machine.shown.conversation.end, .completed, "retour sur le fil : son état final est là")
    }

    /// Cas 4 : la réouverture d'un fil pendant son tour (P1 @ 344d2501), pour chaque état final, avec l'erreur de Hermes
    func testReopeningAThreadDuringItsTurnShowsTheEndAndTheErrorHermesGivesIt() throws {
        let ends: [(TurnEnd, String?)] = [(.completed, nil), (.failed, "HTTP 400: hv fake provider failure"), (.cancelled, nil), (.interrupted, "The gateway restarted")]
        for (end, detail) in ends {
            let t = key(a, "t")
            // re-clic sur le fil pendant le tour
            var h = Harness()
            h.apply(.open(session: "t", bot: a))
            h.resolveAll()
            h.apply(.send("premier"))
            h.apply(.open(session: "t", bot: a))
            h.apply(.ended(t, reply: "réponse", end: end, detail: detail))
            XCTAssertEqual(h.machine.shown.conversation.end, end, "re-clic, \(end)")
            XCTAssertEqual(h.machine.shown.conversation.endDetail, detail, "re-clic, \(end)")
            h.resolveAll()
            XCTAssertEqual(h.machine.shown.conversation.end, end, "re-clic, \(end), après la relecture")
            XCTAssertEqual(h.machine.shown.conversation.endDetail, detail)

            // le fil quitté pendant le tour, rouvert après sa fin
            var left = Harness()
            left.apply(.open(session: "t", bot: a))
            left.resolveAll()
            left.apply(.send("premier"))
            left.apply(.select(bot: b))
            left.apply(.ended(t, reply: "réponse", end: end, detail: detail))
            let load = try XCTUnwrap(left.apply(.open(session: "t", bot: a)).first)
            left.resolve(load)
            XCTAssertEqual(left.machine.shown.conversation.end, end, "quitté puis rouvert, \(end)")
            XCTAssertEqual(left.machine.shown.conversation.endDetail, detail, "quitté puis rouvert, \(end)")
        }
    }

    /// Cas 5 : une nouvelle session suivie d'un changement rapide de bot (P2 @ 344d2501)
    func testANewSessionThenAQuickBotSwitchKeepsTheCreationErrorOnItsOwnThread() throws {
        var h = Harness()
        h.apply(.open(session: "old", bot: a))
        h.resolveAll()
        let creation = try XCTUnwrap(h.apply(.newSession).first)
        h.apply(.select(bot: b))
        h.resolve(creation, succeeds: false)
        XCTAssertEqual(h.machine.screen?.bot, b)
        XCTAssertNil(h.machine.shown.conversation.failure, "l'erreur ne s'affiche jamais chez l'autre bot")
        h.apply(.select(bot: a))
        XCTAssertEqual(h.machine.shown.conversation.failure, "échec de création", "retour sur le bot : l'erreur est sur le fil de « Nouvelle session »")
        XCTAssertTrue(h.machine.canSend("bonjour"), "le fil pas encore créé accepte un envoi, qui le crée")
    }

    // MARK: chaque opération en vol, croisée avec chaque autre transition

    private enum Operation: String, CaseIterable {
        case load, create, firstSend, turn, reread
    }

    private enum Interruption: String, CaseIterable {
        case selectOtherBot, openSameBotThread, openOtherBotThread, reclickOrigin, leaveAndReturn, newSession, sendElsewhere
    }

    func testEveryOperationInFlightMeetsEveryOtherTransitionAndItsResultStaysOnItsOwnThread() throws {
        for operation in Operation.allCases {
            for interruption in Interruption.allCases {
                for succeeds in [true, false] {
                    for originFirst in [true, false] {
                        try check(operation, interruption, succeeds: succeeds, originFirst: originFirst)
                    }
                }
            }
        }
    }

    /// Lance l'opération sur le bot a ; rend son fil d'origine et l'opération en vol
    private func start(_ operation: Operation, _ h: inout Harness) throws -> (origin: Key, effect: ConversationMachine.Effect) {
        switch operation {
        case .load:
            return (key(a, "t"), try XCTUnwrap(h.apply(.open(session: "t", bot: a)).first))
        case .create:
            h.apply(.select(bot: a))
            let effect = try XCTUnwrap(h.apply(.newSession).first)
            return (try XCTUnwrap(h.machine.screen), effect)
        case .firstSend:
            h.apply(.select(bot: a))
            let effect = try XCTUnwrap(h.apply(.send("message")).first)
            return (try XCTUnwrap(h.machine.screen), effect)
        case .turn:
            h.apply(.open(session: "t", bot: a))
            h.resolveAll()
            return (key(a, "t"), try XCTUnwrap(h.apply(.send("message")).first))
        case .reread:
            h.apply(.open(session: "t", bot: a))
            h.resolveAll()
            let run = try XCTUnwrap(h.apply(.send("message")).first)
            return (key(a, "t"), try XCTUnwrap(h.resolve(run).first))
        }
    }

    private func interrupt(_ interruption: Interruption, origin: Key, _ h: inout Harness) throws {
        switch interruption {
        case .selectOtherBot:
            h.apply(.select(bot: b))
        case .openSameBotThread:
            h.apply(.open(session: "t2", bot: a))
        case .openOtherBotThread:
            h.apply(.open(session: "t3", bot: b))
        case .reclickOrigin:
            back(to: origin, &h)
        case .leaveAndReturn:
            h.apply(.select(bot: b))
            back(to: origin, &h)
        case .newSession:
            h.apply(.newSession)
        case .sendElsewhere:
            h.resolve(try XCTUnwrap(h.apply(.open(session: "t2", bot: a)).first))
            h.apply(.send("ailleurs"))
        }
    }

    private func back(to origin: Key, _ h: inout Harness) {
        if let session = origin.session {
            h.apply(.open(session: session, bot: origin.bot))
        } else {
            h.apply(.select(bot: origin.bot))
        }
    }

    private func check(_ operation: Operation, _ interruption: Interruption, succeeds: Bool, originFirst: Bool) throws {
        let label = "\(operation.rawValue) puis \(interruption.rawValue), \(succeeds ? "succès" : "échec"), \(originFirst ? "origine d'abord" : "les autres d'abord")"
        var h = Harness()
        let (origin, effect) = try start(operation, &h)
        try interrupt(interruption, origin: origin, &h)
        // seule une relecture du fil d'origine, relancée par un re-clic, le vise aussi
        let touchesOrigin = h.inFlight.contains { $0 != effect && $0.key == origin }

        if !originFirst {
            let before = h.machine.threads[origin]
            while let other = h.inFlight.first(where: { $0 != effect }) { h.resolve(other) }
            if !touchesOrigin { XCTAssertEqual(h.machine.threads[origin], before, "\(label) : une autre opération a changé le fil d'origine") }
        }

        let screen = h.machine.screen
        let screenState = screen.flatMap { h.machine.threads[$0] }
        // le résultat de l'opération d'origine, puis ce qu'il lance dans son propre fil
        var chain = [effect]
        var emitted: [ConversationMachine.Effect] = []
        var first = true
        while !chain.isEmpty {
            let next = chain.removeFirst()
            let started = h.resolve(next, succeeds: first ? succeeds : true)
            first = false
            emitted += started
            chain += started
        }
        let landed = h.created[origin].map { key(origin.bot, $0) } ?? origin
        // la relecture relancée par le re-clic remplace le résultat d'origine : on juge l'état final
        if originFirst, touchesOrigin { h.resolveAll() }

        // jamais affiché ailleurs
        if screen == origin {
            XCTAssertEqual(h.machine.screen, landed, "\(label) : l'écran suit son fil")
        } else {
            XCTAssertEqual(h.machine.screen, screen, "\(label) : le résultat a déplacé l'écran")
            XCTAssertEqual(screen.flatMap { h.machine.threads[$0] }, screenState, "\(label) : le résultat a changé le fil à l'écran")
        }
        for started in emitted { XCTAssertEqual(started.key, landed, "\(label) : \(started) vise un autre fil") }
        XCTAssertTrue(h.threadsChanged.allSatisfy { $0 == a }, "\(label) : liste relue chez un autre bot \(h.threadsChanged)")

        // jamais perdu : le fil d'origine porte le résultat
        let result = try XCTUnwrap(h.machine.threads[landed], "\(label) : le fil d'origine a disparu")
        XCTAssertEqual(result.step, .ready, label)
        let texts = result.conversation.entries.map(\.text)
        switch (operation, succeeds) {
        case (.load, true):
            XCTAssertEqual(texts, ["question de t", "réponse de t"], label)
        case (.load, false):
            XCTAssertEqual(result.conversation.failure, "échec de lecture", label)
        case (.create, true):
            XCTAssertNotEqual(landed, origin, label)
            XCTAssertTrue(texts.isEmpty, label)
            XCTAssertNil(result.conversation.failure, label)
        case (.create, false):
            XCTAssertEqual(result.conversation.failure, "échec de création", label)
        case (.firstSend, true), (.turn, true):
            XCTAssertEqual(Array(texts.suffix(2)), ["message", "réponse"], label)
            XCTAssertEqual(result.conversation.end, .completed, label)
        case (.firstSend, false):
            XCTAssertEqual(texts, ["message"], "\(label) : le message reste dans son fil")
            XCTAssertEqual(result.conversation.failure, "échec de création", label)
        case (.turn, false):
            XCTAssertEqual(texts.last, "message", "\(label) : le message reste dans son fil")
            XCTAssertEqual(result.conversation.failure, "échec du tour", label)
        case (.reread, true):
            XCTAssertEqual(result.conversation.end, .completed, label)
            XCTAssertFalse(result.conversation.entries.contains { $0.serverIndex == nil }, "\(label) : lignes numérotées")
        case (.reread, false):
            XCTAssertEqual(result.conversation.end, .completed, label)
        }

        if originFirst, !touchesOrigin {
            let after = h.machine.threads[landed]
            h.resolveAll()
            XCTAssertEqual(h.machine.threads[landed], after, "\(label) : une autre opération a changé le fil d'origine")
        }
        XCTAssertTrue(h.inFlight.isEmpty, label)
        XCTAssertTrue(h.machine.threads.values.allSatisfy { $0.step == .ready }, "\(label) : un fil reste bloqué")
    }

    // MARK: changer le modèle de la session (HD-10)

    /// Un fil ouvert, lu et prêt, sur le bot `a`
    private func openedThread(_ session: String = "t") -> Harness {
        var h = Harness()
        h.apply(.open(session: session, bot: a))
        h.resolveAll()
        return h
    }

    func testPickingAModelAsksHermesOnceAndTheSelectorChangesOnlyWhenHermesConfirms() throws {
        var h = openedThread()
        XCTAssertNil(h.machine.shown.model, "avant tout choix, le fil suit le modèle du profil")
        let lock = try XCTUnwrap(h.apply(.pickModel("model-y")).first)
        XCTAssertEqual(lock, .setModel(key(a, "t"), model: "model-y"))
        XCTAssertEqual(h.machine.shown.pendingModel, "model-y", "le sélecteur attend")
        XCTAssertNil(h.machine.shown.model, "le modèle affiché ne change qu'à la confirmation")

        h.resolve(lock)
        XCTAssertEqual(h.machine.shown.model, "model-y")
        XCTAssertNil(h.machine.shown.pendingModel)
        XCTAssertNil(h.machine.shown.modelError)
    }

    /// Lane 6 : le même choix deux fois de suite ne part qu'une fois
    func testTheSameChoiceTwiceFastSendsOneRequest() throws {
        var h = openedThread()
        XCTAssertEqual(h.apply(.pickModel("model-y")).count, 1)
        XCTAssertEqual(h.apply(.pickModel("model-y")), [], "le second appel trouve le choix en vol")
        XCTAssertEqual(h.apply(.pickModel("model-z")), [], "un autre choix attend la confirmation du premier")
        XCTAssertEqual(h.machine.shown.pendingModel, "model-y")
        h.resolveAll()
        XCTAssertEqual(h.apply(.pickModel("model-y")), [], "le modèle déjà verrouillé ne se redemande pas")
        XCTAssertEqual(h.apply(.pickModel("model-z")), [.setModel(key(a, "t"), model: "model-z")])
    }

    func testTheChosenModelGoesInEveryRunOfThatThreadAndOnlyThere() throws {
        var h = openedThread()
        h.apply(.pickModel("model-y"))
        h.resolveAll()
        XCTAssertEqual(h.apply(.send("bonjour")), [.run(key(a, "t"), message: "bonjour", model: "model-y")], "POST /v1/runs ignore le verrou de la session (S4)")
        h.resolveAll()
        XCTAssertEqual(h.apply(.send("encore")), [.run(key(a, "t"), message: "encore", model: "model-y")])
        h.resolveAll()

        h.apply(.open(session: "u", bot: a))
        h.resolveAll()
        XCTAssertNil(h.machine.shown.model, "un autre fil du même bot garde le modèle du profil")
        XCTAssertEqual(h.apply(.send("ailleurs")), [.run(key(a, "u"), message: "ailleurs", model: nil)])
    }

    /// Lane 2 : le choix reste sur la session, pas sur les nouvelles
    func testANewSessionStartsOnTheProfileModelAndTheOldThreadKeepsItsChoice() throws {
        var h = openedThread()
        h.apply(.pickModel("model-y"))
        h.resolveAll()
        h.apply(.newSession)
        h.resolveAll()
        XCTAssertEqual(h.machine.screen, key(a, "créé-1"))
        XCTAssertNil(h.machine.shown.model)
        XCTAssertEqual(h.machine.threads[key(a, "t")]?.model, "model-y")
    }

    /// Lane 9 : un fil rouvert montre le modèle que sa session a déjà
    func testAThreadOpenedForTheFirstTimeTakesTheModelOfItsListEntry() throws {
        var h = Harness()
        h.apply(.open(session: "t", bot: a, model: "hv-fake-2", read: 1))
        h.resolveAll()
        XCTAssertEqual(h.machine.shown.model, "hv-fake-2")
        XCTAssertEqual(h.apply(.send("bonjour")), [.run(key(a, "t"), message: "bonjour", model: "hv-fake-2")], "le fil verrouillé par un autre client continue sur son modèle")
    }

    /// Un fil connu prend le modèle que la liste lui donne quand elle a été relue depuis qu'il a été vu : un autre client a pu le verrouiller entre deux ouvertures
    func testAKnownThreadTakesTheModelThatTheListGaveSinceItWasLastOpened() throws {
        var h = Harness()
        h.apply(.open(session: "t", bot: a))
        h.resolveAll()
        XCTAssertNil(h.machine.shown.model)
        h.apply(.open(session: "u", bot: a))
        h.resolveAll()

        h.apply(.open(session: "t", bot: a, model: "server-new-model", read: 1))
        XCTAssertEqual(h.machine.shown.model, "server-new-model", "la liste relue a un modèle que l'app ne connaissait pas")
        h.resolveAll()
        XCTAssertEqual(h.apply(.send("bonjour")), [.run(key(a, "t"), message: "bonjour", model: "server-new-model")])
        h.resolveAll()

        // le modèle de la liste change encore : le fil le prend de nouveau
        h.apply(.open(session: "u", bot: a))
        h.resolveAll()
        h.apply(.open(session: "t", bot: a, model: "server-newer-model", read: 2))
        XCTAssertEqual(h.machine.shown.model, "server-newer-model")
    }

    /// La liste des fils garde son ancien modèle tant qu'elle n'est pas relue : un choix fait ici n'est pas défait par cette lecture, partie avant lui
    func testAStaleListEntryDoesNotUndoAChoiceMadeHere() throws {
        var h = Harness()
        h.startedReads = 1
        h.apply(.open(session: "t", bot: a, model: "hv-fake-2", read: 1))
        h.resolveAll()
        h.apply(.pickModel("model-y"))
        h.resolveAll()
        h.apply(.open(session: "u", bot: a))
        h.resolveAll()

        h.apply(.open(session: "t", bot: a, model: "hv-fake-2", read: 1))
        XCTAssertEqual(h.machine.shown.model, "model-y", "la liste n'a pas été relue depuis la dernière ouverture : le choix local fait foi")
        h.resolveAll()

        // la liste relue montre le choix : même modèle
        h.startedReads = 2
        h.apply(.open(session: "u", bot: a))
        h.resolveAll()
        h.apply(.open(session: "t", bot: a, model: "model-y", read: 2))
        XCTAssertEqual(h.machine.shown.model, "model-y")
    }

    /// Verdict FAIL @ 7c19673 : une liste relue après la confirmation du choix local, qui redonne la valeur d'avant ce choix, est une information neuve : un autre client a remis cette valeur
    func testAFreshListThatGivesTheValueFromBeforeALocalChoiceTakesPrecedence() throws {
        var h = Harness()
        h.startedReads = 1
        h.apply(.open(session: "t", bot: a, model: "server-A", read: 1))
        h.resolveAll()
        h.apply(.pickModel("local-B"))
        h.resolveAll()
        XCTAssertEqual(h.machine.shown.model, "local-B")
        h.apply(.open(session: "u", bot: a))
        h.resolveAll()

        // la lecture 2 part après la confirmation
        h.startedReads = 2
        h.apply(.open(session: "t", bot: a, model: "server-A", read: 2))
        XCTAssertEqual(h.machine.shown.model, "server-A", "la lecture 2 est partie après la confirmation : elle fait foi même avec la valeur d'avant le choix")
        h.resolveAll()
        XCTAssertEqual(h.apply(.send("bonjour")), [.run(key(a, "t"), message: "bonjour", model: "server-A")])
    }

    /// Verdict FAIL @ 060716b : une lecture partie avant le choix, en cache ou encore en vol à sa confirmation, ne le défait pas
    /// Choisir B, sortir, rouvrir : le message suivant part avec B ; une lecture partie après la confirmation fait foi
    func testAListReadThatLeftBeforeAConfirmedChoiceDoesNotUndoIt() throws {
        var h = Harness()
        h.startedReads = 1
        h.apply(.open(session: "t", bot: a, model: "server-A", read: 1))
        h.resolveAll()
        // la lecture 2 part avant le choix : elle donne server-A, qu'elle réponde avant ou après la confirmation
        h.startedReads = 2
        h.apply(.pickModel("local-B"))
        h.resolveAll()
        XCTAssertEqual(h.machine.shown.model, "local-B")
        h.apply(.open(session: "u", bot: a))
        h.resolveAll()

        h.apply(.open(session: "t", bot: a, model: "server-A", read: 2))
        XCTAssertEqual(h.machine.shown.model, "local-B", "la lecture 2 est partie avant la confirmation : elle ne voit pas le choix")
        h.resolveAll()
        XCTAssertEqual(h.apply(.send("bonjour")), [.run(key(a, "t"), message: "bonjour", model: "local-B")])
        h.resolveAll()

        // la lecture 3 part après la confirmation : un autre client a verrouillé le fil sur server-C
        h.startedReads = 3
        h.apply(.open(session: "u", bot: a))
        h.resolveAll()
        h.apply(.open(session: "t", bot: a, model: "server-C", read: 3))
        XCTAssertEqual(h.machine.shown.model, "server-C")
    }

    /// Une lecture partie pendant que `set_model` est en vol a pu passer chez Hermes avant le verrou : elle ne défait pas le choix confirmé
    func testAListReadThatLeftWhileThePickWasInFlightDoesNotUndoIt() throws {
        var h = Harness()
        h.startedReads = 1
        h.apply(.open(session: "t", bot: a, model: "server-A", read: 1))
        h.resolveAll()
        let lock = try XCTUnwrap(h.apply(.pickModel("local-B")).first)
        h.startedReads = 2
        h.resolve(lock)
        h.apply(.open(session: "u", bot: a))
        h.resolveAll()

        h.apply(.open(session: "t", bot: a, model: "server-A", read: 2))
        XCTAssertEqual(h.machine.shown.model, "local-B")
    }

    /// Une lecture neuve sans modèle (fil absent ou sans verrou) ne défait pas un modèle confirmé : la lecture a pu partir avant le verrou
    func testAFreshListWithoutAModelDoesNotUndoAConfirmedChoice() throws {
        var h = Harness()
        h.apply(.open(session: "t", bot: a, model: nil, read: 1))
        h.resolveAll()
        h.apply(.pickModel("local-B"))
        h.resolveAll()
        h.apply(.open(session: "u", bot: a))
        h.resolveAll()

        h.apply(.open(session: "t", bot: a, model: nil, read: 2))
        XCTAssertEqual(h.machine.shown.model, "local-B")
    }

    /// Un choix en vol est protégé : la liste ne lui passe pas devant, et sa confirmation fait foi
    func testAPickInFlightIsNotOverwrittenByTheListOfAReopening() throws {
        var h = Harness()
        h.apply(.open(session: "t", bot: a))
        h.resolveAll()
        let lock = try XCTUnwrap(h.apply(.pickModel("model-y")).first)
        h.apply(.open(session: "u", bot: a))
        h.resolveAll(except: lock)

        h.apply(.open(session: "t", bot: a, model: "server-new-model", read: 1))
        XCTAssertNil(h.machine.shown.model)
        XCTAssertEqual(h.machine.shown.pendingModel, "model-y")
        h.resolve(lock)
        XCTAssertEqual(h.machine.shown.model, "model-y")
    }

    /// Le choix fait avant que le fil existe n'est pas un modèle confirmé : il s'affiche, se verrouille à la création, et le premier tour attend la confirmation
    func testAModelPickedBeforeTheThreadExistsIsShownThenLockedOnceItIsCreatedAndTheFirstTurnWaitsForIt() throws {
        var h = Harness()
        h.apply(.select(bot: a))
        XCTAssertEqual(h.apply(.pickModel("model-y")), [], "aucune session où verrouiller")
        XCTAssertEqual(h.machine.shown.chosenModel, "model-y", "le choix s'affiche tout de suite")
        XCTAssertNil(h.machine.shown.model, "mais Hermes ne l'a pas confirmé")
        XCTAssertNil(h.machine.shown.pendingModel)

        let creation = try XCTUnwrap(h.apply(.send("bonjour")).first)
        let lock = h.resolve(creation)
        XCTAssertEqual(lock, [.setModel(key(a, "créé-1"), model: "model-y")], "le tour ne part pas avant la confirmation")
        XCTAssertEqual(h.machine.shown.step, .sending)
        XCTAssertEqual(h.machine.shown.pendingModel, "model-y", "le verrou attend sa confirmation")
        XCTAssertNil(h.machine.shown.chosenModel)
        XCTAssertNil(h.machine.shown.model)

        let run = h.resolve(try XCTUnwrap(lock.first))
        XCTAssertEqual(run, [.run(key(a, "créé-1"), message: "bonjour", model: "model-y")], "le premier tour part sur le modèle confirmé")
        XCTAssertEqual(h.machine.shown.model, "model-y")
        XCTAssertNil(h.machine.shown.pendingModel)
        h.resolveAll()
        XCTAssertEqual(h.machine.shown.step, .ready)
        XCTAssertEqual(h.machine.shown.conversation.end, .completed)
    }

    /// Le verrou refusé après la création abandonne le choix : le modèle refusé n'est ni montré ni envoyé, et le premier tour ne part pas
    func testARefusedLockAfterTheCreationDropsTheChoiceAndNoRunUsesTheRefusedModel() throws {
        var h = Harness()
        h.apply(.select(bot: a))
        h.apply(.pickModel("model-y"))
        let creation = try XCTUnwrap(h.apply(.send("bonjour")).first)
        let lock = try XCTUnwrap(h.resolve(creation).first)

        XCTAssertEqual(h.resolve(lock, succeeds: false), [], "aucun tour ne part sur un autre modèle que celui qui a été choisi")
        let thread = h.machine.shown
        XCTAssertNil(thread.model, "le modèle refusé n'est pas confirmé")
        XCTAssertNil(thread.chosenModel, "le choix refusé est abandonné")
        XCTAssertNil(thread.pendingModel)
        XCTAssertEqual(thread.modelError, "échec du modèle")
        XCTAssertEqual(thread.step, .ready)
        XCTAssertEqual(thread.conversation.failure, "échec du modèle", "le tour n'a pas commencé : l'écran le dit")
        XCTAssertTrue(h.inFlight.isEmpty)

        // le fil existe et suit le modèle du profil : le tour suivant n'emporte pas le modèle refusé
        XCTAssertEqual(h.apply(.send("encore")), [.run(key(a, "créé-1"), message: "encore", model: nil)])
    }

    /// Le même refus sans message en attente : « Nouvelle session » avec un choix fait avant sa création
    func testARefusedLockAfterANewSessionCreationDropsTheChoice() throws {
        var h = Harness()
        h.apply(.select(bot: a))
        let creation = try XCTUnwrap(h.apply(.newSession).first)
        h.apply(.pickModel("model-y"))
        XCTAssertEqual(h.machine.shown.chosenModel, "model-y")
        let lock = try XCTUnwrap(h.resolve(creation).first)
        XCTAssertEqual(lock, .setModel(key(a, "créé-1"), model: "model-y"))
        h.resolve(lock, succeeds: false)
        XCTAssertNil(h.machine.shown.model)
        XCTAssertNil(h.machine.shown.chosenModel)
        XCTAssertEqual(h.machine.shown.modelError, "échec du modèle")
        XCTAssertNil(h.machine.shown.conversation.failure, "aucun tour n'attendait")
        XCTAssertEqual(h.machine.shown.step, .ready)
        XCTAssertEqual(h.apply(.send("bonjour")), [.run(key(a, "créé-1"), message: "bonjour", model: nil)])
    }

    func testAModelPickedBeforeANewSessionExistsIsLockedWhenItIsCreated() throws {
        var h = Harness()
        h.apply(.select(bot: a))
        let creation = try XCTUnwrap(h.apply(.newSession).first)
        XCTAssertEqual(h.apply(.pickModel("model-y")), [])
        XCTAssertEqual(h.resolve(creation), [.setModel(key(a, "créé-1"), model: "model-y")])
        h.resolveAll()
        XCTAssertEqual(h.machine.shown.model, "model-y")
        XCTAssertNil(h.machine.shown.chosenModel)
    }

    func testARefusedPickKeepsTheModelNamesTheErrorAndTheNextPickClearsIt() throws {
        var h = openedThread()
        h.apply(.pickModel("model-y"))
        h.resolveAll()
        let lock = try XCTUnwrap(h.apply(.pickModel("model-z")).first)
        h.resolve(lock, succeeds: false)
        XCTAssertEqual(h.machine.shown.model, "model-y", "un choix refusé ne change pas le modèle affiché")
        XCTAssertNil(h.machine.shown.pendingModel, "le sélecteur est de nouveau libre")
        XCTAssertEqual(h.machine.shown.modelError, "échec du modèle")
        XCTAssertEqual(h.machine.shown.step, .ready)
        XCTAssertNil(h.machine.shown.conversation.failure, "l'échec du verrou n'est pas un échec du tour")

        h.apply(.pickModel("model-z"))
        XCTAssertNil(h.machine.shown.modelError)
    }

    /// Lane 7 : le choix pendant un tour s'applique au tour suivant, le tour en cours finit comme avant
    func testAPickDuringATurnLeavesTheTurnAloneAndAppliesFromTheNextOne() throws {
        var h = openedThread()
        let run = try XCTUnwrap(h.apply(.send("bonjour")).first)
        XCTAssertEqual(run, .run(key(a, "t"), message: "bonjour", model: nil))
        let lock = try XCTUnwrap(h.apply(.pickModel("model-y")).first)
        XCTAssertEqual(h.machine.shown.step, .sending, "le tour continue")
        XCTAssertFalse(h.machine.canSend("suite"))

        h.resolve(lock)
        XCTAssertEqual(h.machine.shown.model, "model-y")
        XCTAssertEqual(h.machine.shown.step, .sending, "la confirmation ne touche pas au tour")
        h.resolve(run)
        XCTAssertEqual(h.machine.shown.conversation.end, .completed)
        XCTAssertNil(h.machine.shown.conversation.failure)
        h.resolveAll()
        XCTAssertEqual(h.apply(.send("suite")), [.run(key(a, "t"), message: "suite", model: "model-y")])
    }

    func testTheAnswerOfAPickStaysOnTheThreadThatAskedAndAStaleOneChangesNothing() throws {
        var h = openedThread()
        let lock = try XCTUnwrap(h.apply(.pickModel("model-y")).first)
        h.apply(.open(session: "u", bot: a))
        h.resolveAll(except: lock)
        XCTAssertNil(h.machine.shown.model, "l'écran est sur un autre fil")
        h.resolve(lock)
        XCTAssertEqual(h.machine.threads[key(a, "t")]?.model, "model-y")
        XCTAssertNil(h.machine.threads[key(a, "u")]?.model)

        // une confirmation sans choix en vol (dépassée) ne change rien
        let before = h.machine
        XCTAssertEqual(h.apply(.modelSet(key(a, "t"), model: "autre")), [])
        XCTAssertEqual(h.apply(.modelFailed(key(a, "t"), "tard")), [])
        XCTAssertEqual(h.machine, before)
    }

    /// Lane 3 : le nom est celui que Hermes envoie, sans correction
    func testTheModelNameIsKeptAsHermesSentIt() throws {
        var h = openedThread()
        h.apply(.pickModel("model-y"))
        h.apply(.modelSet(key(a, "t"), model: "  Modèle (x) 9 — é "))
        XCTAssertEqual(h.machine.shown.model, "  Modèle (x) 9 — é ")
    }

    func testWithoutAThreadOnScreenAPickAsksNothing() {
        var h = Harness()
        XCTAssertEqual(h.apply(.pickModel("model-y")), [])
    }

    // MARK: l'outil en cours et les approbations (HD-11)

    private let ask = ApprovalRequest(requestID: "r1", executionGeneration: nil, command: "/tmp/hv.txt", description: "écrire le fichier", choices: ["once", "deny"], tool: "file.write")

    /// Un tour parti dans le fil `t`, dont le run est `run-1`
    private func runningTurn() -> Harness {
        var h = openedThread()
        h.apply(.send("go"))
        h.apply(.runStarted(key(a, "t"), run: "run-1"))
        return h
    }

    func testTheRunIdIsKeptForTheThreadThatStartedIt() {
        var h = runningTurn()
        XCTAssertEqual(h.machine.threads[key(a, "t")]?.run, "run-1")
        // un run annoncé à un fil qui n'envoie rien est dépassé
        var idle = openedThread()
        XCTAssertEqual(idle.apply(.runStarted(key(a, "t"), run: "run-9")), [])
        XCTAssertNil(idle.machine.threads[key(a, "t")]?.run)
    }

    func testTheCurrentToolFollowsWhatHermesObservesAndStaysOnItsThread() {
        var h = runningTurn()
        XCTAssertNil(h.machine.shown.tool)
        h.apply(.observed(key(a, "t"), tool: "shell.exec", approval: nil))
        XCTAssertEqual(h.machine.shown.tool, "shell.exec")
        h.apply(.observed(key(a, "t"), tool: nil, approval: nil))
        XCTAssertNil(h.machine.shown.tool, "l'outil disparaît à sa fin")
        // un fil qui n'est pas à l'écran garde son outil, l'écran ne le montre pas
        h.apply(.observed(key(a, "t"), tool: "shell.exec", approval: nil))
        h.apply(.open(session: "u", bot: a))
        XCTAssertNil(h.machine.shown.tool)
        XCTAssertEqual(h.machine.threads[key(a, "t")]?.tool, "shell.exec")
    }

    func testAnObservationOfAThreadThatSendsNothingIsStale() {
        var h = openedThread()
        XCTAssertEqual(h.apply(.observed(key(a, "t"), tool: "shell.exec", approval: ask)), [])
        XCTAssertNil(h.machine.shown.tool)
        XCTAssertNil(h.machine.shown.pendingApproval)
    }

    func testAnApprovalRequestWaitsForTheUserAndAsksForTheCapabilityProbeOnce() {
        var h = runningTurn()
        XCTAssertEqual(h.apply(.observed(key(a, "t"), tool: "file.write", approval: ask)), [.probeApprove(key(a, "t"))])
        let approval = h.machine.shown.pendingApproval
        XCTAssertEqual(approval?.request, ask)
        XCTAssertNil(approval?.decision, "le bot attend la réponse de l'utilisateur")
        XCTAssertEqual(h.machine.shown.tool, "file.write")
        // la même demande, vue de nouveau (un autre événement du flux), ne change rien
        let before = h.machine
        XCTAssertEqual(h.apply(.observed(key(a, "t"), tool: "file.write", approval: ask)), [])
        XCTAssertEqual(h.machine, before)
    }

    func testAnAnswerSendsOneDecisionEvenOnADoubleClick() {
        var h = runningTurn()
        h.apply(.observed(key(a, "t"), tool: "file.write", approval: ask))
        XCTAssertEqual(h.apply(.answer(.yes)), [.approve(key(a, "t"), run: "run-1", request: ask, decision: .yes)])
        XCTAssertEqual(h.apply(.answer(.yes)), [], "le second clic d'un double clic trouve la décision prise")
        XCTAssertEqual(h.apply(.answer(.no)), [], "une décision prise ne change pas")
        XCTAssertEqual(h.machine.shown.pendingApproval?.decision, .yes)
        XCTAssertEqual(ConversationMachine.Decision.yes.choice, "once")
        XCTAssertEqual(ConversationMachine.Decision.no.choice, "deny")
    }

    func testWithoutAPendingApprovalAnAnswerAsksNothing() {
        var h = runningTurn()
        XCTAssertEqual(h.apply(.answer(.yes)), [])
        h.apply(.observed(key(a, "t"), tool: "file.write", approval: ask))
        let before = h.machine
        // le résultat d'une autre demande ne touche pas à celle-ci
        XCTAssertEqual(h.apply(.approved(key(a, "t"), requestID: "autre")), [])
        XCTAssertEqual(h.apply(.approvalQueued(key(a, "t"), requestID: "autre")), [])
        XCTAssertEqual(h.apply(.approvalFailed(key(a, "t"), requestID: "autre", "x")), [])
        XCTAssertEqual(h.machine, before)
    }

    func testTheDecisionHermesTookClosesTheSheetAndALateObservationDoesNotReopenIt() {
        var h = runningTurn()
        h.apply(.observed(key(a, "t"), tool: "file.write", approval: ask))
        h.apply(.answer(.yes))
        h.apply(.approved(key(a, "t"), requestID: "r1"))
        XCTAssertNil(h.machine.shown.pendingApproval, "la feuille se ferme")
        // un événement du flux lu avant `approval.responded` montre encore la demande : elle ne se rouvre pas
        XCTAssertEqual(h.apply(.observed(key(a, "t"), tool: "file.write", approval: ask)), [])
        XCTAssertNil(h.machine.shown.pendingApproval)
        // Hermes l'a résolue : l'état suivant n'a plus de demande ; une nouvelle demande ouvre une nouvelle feuille
        h.apply(.observed(key(a, "t"), tool: "file.write", approval: nil))
        let second = ApprovalRequest(requestID: "r2", executionGeneration: nil, command: "/tmp/b", description: "", choices: [], tool: "file.write")
        XCTAssertEqual(h.apply(.observed(key(a, "t"), tool: "file.write", approval: second)), [.probeApprove(key(a, "t"))])
        XCTAssertEqual(h.machine.shown.pendingApproval?.request, second)
    }

    func testAnApprovalHermesResolvedByItselfClosesTheSheet() {
        var h = runningTurn()
        h.apply(.observed(key(a, "t"), tool: "file.write", approval: ask))
        h.apply(.observed(key(a, "t"), tool: "file.write", approval: nil))
        XCTAssertNil(h.machine.shown.pendingApproval, "délai de Hermes, ou une réponse d'un autre client")
    }

    func testADecisionThatCannotGoOutStaysOnScreenQueued() {
        var h = runningTurn()
        h.apply(.observed(key(a, "t"), tool: "file.write", approval: ask))
        h.apply(.answer(.yes))
        h.apply(.approvalQueued(key(a, "t"), requestID: "r1"))
        let approval = h.machine.shown.pendingApproval
        XCTAssertEqual(approval?.decision, .yes, "la décision est gardée")
        XCTAssertEqual(approval?.isQueued, true)
        XCTAssertEqual(h.apply(.answer(.no)), [], "la décision gardée ne change pas pendant la coupure")
        h.apply(.approved(key(a, "t"), requestID: "r1"))
        XCTAssertNil(h.machine.shown.pendingApproval)
    }

    func testARefusedDecisionFreesTheAnswerAndKeepsTheReason() {
        var h = runningTurn()
        h.apply(.observed(key(a, "t"), tool: "file.write", approval: ask))
        h.apply(.answer(.yes))
        h.apply(.approvalFailed(key(a, "t"), requestID: "r1", "run introuvable"))
        let approval = h.machine.shown.pendingApproval
        XCTAssertNil(approval?.decision)
        XCTAssertEqual(approval?.error, "run introuvable")
        XCTAssertEqual(h.apply(.answer(.no)), [.approve(key(a, "t"), run: "run-1", request: ask, decision: .no)], "l'utilisateur peut répondre de nouveau")
        XCTAssertNil(h.machine.shown.pendingApproval?.error, "la nouvelle réponse efface l'ancienne raison")
    }

    func testTheEndOfTheTurnClearsTheRunTheToolAndTheApproval() {
        for ending in [ConversationMachine.Event.ended(key(a, "t"), reply: "", end: .cancelled, detail: nil), .failed(key(a, "t"), "Hermes n'est pas joignable.")] {
            var h = runningTurn()
            h.apply(.observed(key(a, "t"), tool: "file.write", approval: ask))
            h.apply(.answer(.yes))
            h.apply(ending)
            let thread = h.machine.threads[key(a, "t")]
            XCTAssertNil(thread?.run)
            XCTAssertNil(thread?.tool)
            XCTAssertNil(thread?.approval, "\(ending) : la feuille ne reste pas sur un tour fini")
        }
    }

    func testAnApprovalOfAThreadOffScreenWaitsForTheUserToComeBack() {
        var h = runningTurn()
        h.apply(.observed(key(a, "t"), tool: "file.write", approval: ask))
        h.apply(.open(session: "u", bot: a))
        XCTAssertNil(h.machine.shown.pendingApproval, "l'écran est sur un autre fil")
        XCTAssertEqual(h.apply(.answer(.yes)), [], "une réponse vise le fil à l'écran")
        h.apply(.open(session: "t", bot: a))
        XCTAssertEqual(h.machine.shown.pendingApproval?.request, ask)
        XCTAssertNil(h.machine.shown.pendingApproval?.decision)
    }
}

/// La machine et un faux Hermes : chaque opération reste en vol jusqu'à ce que le test la résolve
private struct Harness {
    var machine = ConversationMachine()
    private(set) var inFlight: [ConversationMachine.Effect] = []
    private(set) var threadsChanged: [String] = []
    /// Le fil chez Hermes que chaque fil pas encore créé est devenu
    private(set) var created: [ConversationMachine.Key: String] = [:]
    /// Le numéro de la dernière lecture de la liste des fils partie, comme `BotsModel.startedReads` : la confirmation d'un choix le retient
    var startedReads = 0

    /// Applique un événement ; rend les opérations qu'il lance
    @discardableResult
    mutating func apply(_ event: ConversationMachine.Event) -> [ConversationMachine.Effect] {
        var started: [ConversationMachine.Effect] = []
        for effect in machine.handle(event) {
            if case .threadsChanged(let bot) = effect { threadsChanged.append(bot) } else { started.append(effect) }
        }
        inFlight += started
        return started
    }

    /// Répond à une opération en vol comme Hermes, par un succès ou un échec ; rend les opérations que la réponse lance
    @discardableResult
    mutating func resolve(_ effect: ConversationMachine.Effect, succeeds: Bool = true) -> [ConversationMachine.Effect] {
        guard let index = inFlight.firstIndex(of: effect) else {
            XCTFail("\(effect) n'est pas en vol")
            return []
        }
        inFlight.remove(at: index)
        switch effect {
        case .load(let key):
            return apply(succeeds ? .loaded(key, [(1, .user, "question de \(key.session ?? "?")"), (2, .assistant, "réponse de \(key.session ?? "?")")]) : .failed(key, "échec de lecture"))
        case .create(let key, let message):
            guard succeeds else { return apply(.failed(key, "échec de création")) }
            let session = "créé-\(created.count + 1)"
            created[key] = session
            return apply(.created(key, session: session, message: message))
        case .setModel(let key, let model):
            guard succeeds else { return apply(.modelFailed(key, "échec du modèle")) }
            return apply(.modelSet(key, model: model, read: startedReads))
        case .run(let key, _, _):
            guard succeeds else { return apply(.failed(key, "échec du tour")) }
            apply(.streamed(key, "rép"))
            return apply(.ended(key, reply: "réponse", end: .completed, detail: nil))
        case .reread(let key, let turn):
            // une relecture qui échoue ne rend rien à la machine
            guard succeeds else { return [] }
            let entries = machine.threads[key]?.conversation.entries ?? []
            return apply(.reread(key, turn: turn, entries.enumerated().map { (100 + $0.offset, $0.element.role, $0.element.text) }))
        case .approve(let key, _, let request, _):
            guard succeeds else { return apply(.approvalFailed(key, requestID: request.requestID, "échec de la réponse")) }
            return apply(.approved(key, requestID: request.requestID))
        case .probeApprove:
            // la sonde est l'affaire du modèle : elle ne rend rien à la machine
            return []
        case .threadsChanged:
            return []
        }
    }

    /// Répond à toutes les opérations en vol, et à celles que leurs réponses lancent ; `held` reste en vol
    mutating func resolveAll(except held: ConversationMachine.Effect? = nil) {
        while let next = inFlight.first(where: { $0 != held }) { resolve(next) }
    }
}

private extension ConversationMachine.Effect {
    var key: ConversationMachine.Key? {
        switch self {
        case .load(let key), .create(let key, _), .run(let key, _, _), .reread(let key, _), .setModel(let key, _), .approve(let key, _, _, _), .probeApprove(let key): key
        case .threadsChanged: nil
        }
    }
}
