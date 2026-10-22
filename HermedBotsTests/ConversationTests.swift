import XCTest

// compilé dans le paquet de tests lui-même, sans l'app comme hôte
final class ConversationTests: XCTestCase {
    private typealias Line = (serverIndex: Int, role: ConversationEntry.Role, text: String)

    private let transcript: [Line] = [(13, .user, "Bonjour"), (14, .assistant, "Réponse de test")]

    // MARK: envoi

    func testABlankOrWhitespaceDraftIsNeverSent() {
        let conversation = Conversation()
        for draft in ["", " ", "   ", "\n", "\t \n  "] {
            XCTAssertFalse(conversation.canSend(draft), "« \(draft.debugDescription) »")
            var copy = conversation
            XCTAssertNil(copy.begin(draft))
            XCTAssertEqual(copy, conversation, "un brouillon vide ne change rien")
        }
        XCTAssertTrue(conversation.canSend("a"))
        XCTAssertTrue(conversation.canSend("  a  "))
    }

    func testBeginAddsTheTrimmedUserLineAndStartsTheTurn() {
        var conversation = Conversation()
        XCTAssertEqual(conversation.begin("  Bonjour hv \n"), "Bonjour hv")
        XCTAssertEqual(conversation.phase, .running)
        XCTAssertEqual(conversation.entries.map(\.role), [.user])
        XCTAssertEqual(conversation.entries.map(\.text), ["Bonjour hv"])
        XCTAssertEqual(conversation.entries.map(\.serverIndex), [nil], "Hermes n'a pas encore numéroté le message")
        XCTAssertNil(conversation.end)
    }

    func testASecondSendWhileATurnRunsIsRefusedAndChangesNothing() {
        var conversation = Conversation()
        XCTAssertNotNil(conversation.begin("un"))
        let running = conversation
        XCTAssertFalse(conversation.canSend("deux"))
        XCTAssertNil(conversation.begin("deux"))
        XCTAssertNil(conversation.begin("deux"))
        XCTAssertEqual(conversation, running, "un double clic ne part qu'une fois")
    }

    func testALongMessageIsKeptWhole() {
        var conversation = Conversation()
        let text = String(repeating: "é", count: 100_000)
        XCTAssertEqual(conversation.begin(text)?.count, 100_000)
        XCTAssertEqual(conversation.entries.first?.text.count, 100_000)
    }

    // MARK: réponse en flux et état terminal

    func testTheReplyGrowsInOneLineAsTheTextArrives() {
        var conversation = Conversation()
        _ = conversation.begin("Bonjour")
        conversation.receive(reply: "")
        XCTAssertEqual(conversation.entries.count, 1, "pas de ligne de réponse avant le premier texte")
        conversation.receive(reply: "Rép")
        conversation.receive(reply: "Réponse de test")
        XCTAssertEqual(conversation.entries.map(\.role), [.user, .assistant])
        XCTAssertEqual(conversation.entries.last?.text, "Réponse de test")
        XCTAssertEqual(conversation.phase, .running, "le tour dure jusqu'à son état terminal")
    }

    func testEveryRealTerminalStateIsKeptAsItIs() {
        for end in [TurnEnd.completed, .failed, .cancelled, .interrupted] {
            var conversation = Conversation()
            _ = conversation.begin("Bonjour")
            conversation.finish(end)
            XCTAssertEqual(conversation.end, end)
            XCTAssertEqual(conversation.phase, .idle)
            XCTAssertNil(conversation.failure)
            XCTAssertTrue(conversation.canSend("suite"), "après \(end.rawValue) on peut écrire de nouveau")
        }
    }

    func testTheErrorHermesGivesWithAnEndStaysWithItUntilTheNextTurn() {
        var conversation = Conversation()
        _ = conversation.begin("Bonjour")
        conversation.finish(.failed, detail: "HTTP 400: hv fake provider failure")
        XCTAssertEqual(conversation.end, .failed)
        XCTAssertEqual(conversation.endDetail, "HTTP 400: hv fake provider failure")
        conversation.finish(.cancelled)
        XCTAssertNil(conversation.endDetail, "une fin sans détail n'en garde pas un ancien")
        conversation.finish(.failed, detail: "x")
        _ = conversation.begin("suite")
        XCTAssertNil(conversation.endDetail)
    }

    func testALostStreamHasAMessageAndNoInventedState() {
        var conversation = Conversation()
        _ = conversation.begin("Bonjour")
        conversation.fail("Hermes injoignable")
        XCTAssertNil(conversation.end)
        XCTAssertEqual(conversation.failure, "Hermes injoignable")
        XCTAssertEqual(conversation.phase, .idle)
    }

    func testANewSendClearsTheLastStateAndFailure() {
        var conversation = Conversation()
        _ = conversation.begin("un")
        conversation.finish(.failed)
        _ = conversation.begin("deux")
        XCTAssertNil(conversation.end)
        _ = conversation.fail("coupé")
        _ = conversation.begin("trois")
        XCTAssertNil(conversation.failure)
        XCTAssertEqual(conversation.entries.map(\.text), ["un", "deux", "trois"])
    }

    // MARK: transcript

    func testOpeningAThreadShowsItsTranscriptWithTheServerIndexAndKeepsTheEndOfItsLastTurn() {
        // le transcript de Hermes ne porte pas l'état final du tour : rouvrir le fil ne doit pas l'effacer (P1 @ 344d2501)
        var conversation = Conversation()
        _ = conversation.begin("avant")
        conversation.finish(.failed, detail: "HTTP 400: hv fake provider failure")
        conversation.fail("lecture coupée")
        conversation.open(transcript)
        XCTAssertEqual(conversation.entries.map(\.serverIndex), [13, 14])
        XCTAssertEqual(conversation.entries.map(\.role), [.user, .assistant])
        XCTAssertEqual(conversation.entries.map(\.text), ["Bonjour", "Réponse de test"])
        XCTAssertEqual(conversation.end, .failed)
        XCTAssertEqual(conversation.endDetail, "HTTP 400: hv fake provider failure")
        XCTAssertNil(conversation.failure, "une lecture réussie remplace l'erreur de la lecture d'avant")
        XCTAssertEqual(conversation.phase, .idle)
    }

    func testAReadThatFailsAfterATurnKeepsTheEndOfThatTurn() {
        var conversation = Conversation()
        _ = conversation.begin("Bonjour")
        conversation.finish(.completed)
        conversation.fail("Hermes n'est pas joignable.")
        XCTAssertEqual(conversation.end, .completed, "l'échec d'une lecture du fil n'efface pas le résultat du tour")
        XCTAssertEqual(conversation.failure, "Hermes n'est pas joignable.")
    }

    func testReadingTheTranscriptAgainGivesTheLinesTheirIndexAndKeepsTheState() {
        var conversation = Conversation()
        _ = conversation.begin("Bonjour")
        conversation.receive(reply: "Réponse de test")
        conversation.finish(.completed)
        let keys = conversation.entries.map(\.id)
        conversation.sync(transcript)
        XCTAssertEqual(conversation.entries.map(\.serverIndex), [13, 14])
        XCTAssertEqual(conversation.entries.map(\.id), keys, "les lignes gardent leur clé de liste : l'écran ne se redessine pas")
        XCTAssertEqual(conversation.end, .completed)
    }

    func testAStateTranscriptThatDisagreesWithTheScreenReplacesTheScreen() {
        // un tour échoué : Hermes a gardé le message user seul
        var conversation = Conversation()
        _ = conversation.begin("Bonjour")
        conversation.receive(reply: "début de réponse")
        conversation.finish(.interrupted)
        conversation.sync([(13, .user, "Bonjour")])
        XCTAssertEqual(conversation.entries.map(\.text), ["Bonjour"])
        XCTAssertEqual(conversation.end, .interrupted)
    }

    func testAnEmptyTranscriptEmptiesTheLinesAndKeepsTheEnd() {
        var conversation = Conversation()
        conversation.open(transcript)
        _ = conversation.begin("suite")
        conversation.finish(.completed)
        conversation.open([])
        XCTAssertTrue(conversation.entries.isEmpty)
        XCTAssertEqual(conversation.end, .completed)
        XCTAssertEqual(conversation.phase, .idle)
    }
}
