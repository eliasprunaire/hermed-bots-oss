import os
import XCTest

@MainActor
final class BotListUnavailableTests: XCTestCase {
    func testAFailedProfileListShowsAFixedCopyAndRecordsTheRawErrorInTheJournal() async {
        XCTAssertEqual(
            BotsModel.listUnavailableMessage,
            "Liste des bots indisponible. Réessayez quand la liaison est rétablie."
        )
        XCTAssertFalse(BotsModel.listUnavailableMessage.contains("Error Domain"))
        XCTAssertFalse(BotsModel.listUnavailableMessage.contains("NSURLError"))

        let lines = OSAllocatedUnfairLock(initialState: [String]())
        let previous = BotsModel.journalSink.withLock { sink in
            defer { sink = { line in lines.withLock { $0.append(line) } } }
            return sink
        }
        defer { BotsModel.journalSink.withLock { $0 = previous } }

        let bots = BotsModel(
            readProfiles: { throw URLError(.cannotConnectToHost) },
            client: { nil },
            connection: { "lab.invalid" }
        )
        await bots.refresh()
        guard case .failed(let stored) = bots.phase else { return XCTFail("\(bots.phase)") }
        XCTAssertNotEqual(stored, BotsModel.listUnavailableMessage)
        XCTAssertNotEqual(stored, "")
        let recorded = lines.withLock { $0 }
        XCTAssertTrue(recorded.contains { $0.contains("liste des bots") }, recorded.joined(separator: "\n"))
    }

    func testAMissingRemoteToolStillKeepsItsClassifiedMessage() async {
        let bots = BotsModel(
            readProfiles: { throw SSHFailure.remoteToolNotFound },
            client: { nil },
            connection: { "lab.invalid" }
        )
        await bots.refresh()
        XCTAssertEqual(bots.phase, .toolNotFound(SSHFailure.remoteToolNotFound.message))
    }
}
