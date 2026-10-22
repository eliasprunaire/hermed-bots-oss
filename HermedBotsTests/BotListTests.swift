import XCTest

// compilé dans le paquet de tests lui-même, sans l'app comme hôte
final class BotListTests: XCTestCase {
    private func bot(_ id: String, model: String? = "hv-fake-1") -> Bot { Bot(id: id, name: id, model: model) }

    private func list(_ ids: String...) -> BotList {
        var list = BotList()
        list.receive(ids.map { bot($0) })
        return list
    }

    func testTheFirstReadIsShownAtOnceWithoutAPrompt() {
        let list = list("hv-bot-a", "hv-bot-b")
        XCTAssertEqual(list.shown?.map(\.id), ["hv-bot-a", "hv-bot-b"])
        XCTAssertNil(list.change)
    }

    func testNothingIsShownBeforeTheFirstRead() {
        XCTAssertNil(BotList().shown)
        XCTAssertNil(BotList().change)
    }

    func testTheSameProfilesAreNotAChangeAndTheModelsRefreshInSilence() {
        var list = list("hv-bot-a", "hv-bot-b")
        list.receive([bot("hv-bot-a", model: "hv-fake-2"), bot("hv-bot-b", model: nil)])
        XCTAssertNil(list.change)
        XCTAssertEqual(list.shown?.map(\.model), ["hv-fake-2", nil])
    }

    func testAnAddedProfileWaitsForTheValidationBeforeItShows() {
        var list = list("hv-bot-a")
        list.receive([bot("hv-bot-a"), bot("hv-new")])
        XCTAssertEqual(list.shown?.map(\.id), ["hv-bot-a"])
        XCTAssertEqual(list.change, BotList.Change(added: ["hv-new"], removed: []))
        list.validate()
        XCTAssertEqual(list.shown?.map(\.id), ["hv-bot-a", "hv-new"])
        XCTAssertNil(list.change)
    }

    func testARemovedProfileStaysUntilTheValidationToo() {
        var list = list("hv-bot-a", "hv-bot-b")
        list.receive([bot("hv-bot-a")])
        XCTAssertEqual(list.shown?.map(\.id), ["hv-bot-a", "hv-bot-b"])
        XCTAssertEqual(list.change, BotList.Change(added: [], removed: ["hv-bot-b"]))
        list.validate()
        XCTAssertEqual(list.shown?.map(\.id), ["hv-bot-a"])
    }

    func testAChangeThatIsUndoneBeforeTheValidationLeavesNoPrompt() {
        var list = list("hv-bot-a")
        list.receive([bot("hv-bot-a"), bot("hv-new")])
        list.receive([bot("hv-bot-a")])
        XCTAssertNil(list.change)
        XCTAssertEqual(list.shown?.map(\.id), ["hv-bot-a"])
    }

    func testTheLatestReadReplacesAPendingChange() {
        var list = list("hv-bot-a")
        list.receive([bot("hv-bot-a"), bot("hv-new")])
        list.receive([bot("hv-bot-a"), bot("hv-newer")])
        XCTAssertEqual(list.change, BotList.Change(added: ["hv-newer"], removed: []))
        list.validate()
        XCTAssertEqual(list.shown?.map(\.id), ["hv-bot-a", "hv-newer"])
    }

    func testValidatingWithoutAChangeChangesNothing() {
        var list = list("hv-bot-a")
        list.validate()
        XCTAssertEqual(list.shown?.map(\.id), ["hv-bot-a"])
        XCTAssertNil(list.change)
    }

    func testAnEmptyFirstReadIsAnEmptyListAndNotAMissingOne() {
        var list = BotList()
        list.receive([])
        XCTAssertEqual(list.shown, [])
        list.receive([bot("hv-bot-a")])
        XCTAssertEqual(list.shown, [])
        XCTAssertEqual(list.change, BotList.Change(added: ["hv-bot-a"], removed: []))
    }

    func testTheShownOrderIsTheOrderOfTheRead() {
        var list = BotList()
        list.receive([bot("default"), bot("cyber"), bot("hv-bot-a")])
        XCTAssertEqual(list.shown?.map(\.id), ["default", "cyber", "hv-bot-a"])
    }
}
