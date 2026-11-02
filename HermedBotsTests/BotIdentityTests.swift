import XCTest

// compilé dans le paquet de tests lui-même, sans l'app comme hôte
final class BotIdentityTests: XCTestCase {
    private func bot(_ id: String, name: String? = nil) -> Bot { Bot(id: id, name: name ?? id, model: nil) }

    func testThePaletteDependsOnlyOnTheProfileID() {
        XCTAssertEqual(bot("hv-bot-a").palette, bot("hv-bot-a", name: "Autre nom").palette)
        XCTAssertNotEqual(bot("hv-bot-a").palette, bot("hv-bot-b").palette)
    }

    func testThePaletteIsTheSameFromOneLaunchToTheNext() {
        // `Hasher` change de graine à chaque lancement : la couleur d'un bot ne doit pas en dépendre
        XCTAssertEqual(bot("default").palette, 6)
        XCTAssertEqual(bot("hv-bot-a").palette, 9)
    }

    func testThePaletteStaysInRangeForAnyID() {
        for id in ["", "default", String(repeating: "x", count: 300), "été 🙂"] {
            XCTAssert((0..<Bot.paletteCount).contains(bot(id).palette), id)
        }
    }

    func testTheMonogramTakesTheFirstLetterOfTheFirstAndLastWords() {
        XCTAssertEqual(bot("hv-bot-a").monogram, "HA")
        XCTAssertEqual(bot("wikilibriste").monogram, "W")
        XCTAssertEqual(bot("x", name: "lead x analyst").monogram, "LA")
        XCTAssertEqual(bot("été").monogram, "É")
        XCTAssertEqual(bot("42_bot").monogram, "4B")
    }

    func testTheMonogramOfANameWithoutLetterOrDigitIsAQuestionMark() {
        XCTAssertEqual(bot("").monogram, "?")
        XCTAssertEqual(bot("--").monogram, "?")
        XCTAssertEqual(bot("🙂").monogram, "?")
    }
}
