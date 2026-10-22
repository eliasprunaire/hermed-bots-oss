import XCTest

// la feuille d'approbation montre les paramètres d'un outil sans en cacher une partie en silence
final class ApprovalParamsTests: XCTestCase {
    func testAShortCommandIsShownAsItIs() {
        let params = ApprovalParams("rm /tmp/hv.txt\n\techo é")
        XCTAssertEqual(params.shown, "rm /tmp/hv.txt\n\techo é", "le saut de ligne et la tabulation restent")
        XCTAssertEqual(params.hidden, 0)
        XCTAssertEqual(params.escaped, 0)
        XCTAssertFalse(params.isChanged)
    }

    func testControlCharactersAreWrittenOutInsteadOfBeingShownAsNothing() {
        let params = ApprovalParams("a\u{0}b\u{1B}[31mc\r\u{7F}")
        XCTAssertEqual(params.shown, #"a\u{0}b\u{1B}[31mc\u{D}\u{7F}"#)
        XCTAssertEqual(params.escaped, 4)
        XCTAssertEqual(params.hidden, 0)
        XCTAssertTrue(params.isChanged)
    }

    func testTextDirectionAndInvisibleCharactersAreWrittenOutBecauseTheyCanDisguiseACommand() {
        // U+202E inverse l'ordre d'affichage de ce qui suit ; U+200B ne se voit pas
        let params = ApprovalParams("ls \u{202E}txt.exe\u{200B}")
        XCTAssertEqual(params.shown, #"ls \u{202E}txt.exe\u{200B}"#)
        XCTAssertEqual(params.escaped, 2)
    }

    func testALongCommandIsCutAtTheLimitAndSaysHowMuchIsHidden() {
        let params = ApprovalParams(String(repeating: "x", count: 25), limit: 10)
        XCTAssertEqual(params.shown, String(repeating: "x", count: 10))
        XCTAssertEqual(params.hidden, 15)
        XCTAssertEqual(params.total, 25)
        XCTAssertTrue(params.isChanged)
    }

    func testTheLimitCountsWhatIsShownSoEscapesCannotGrowTheSheetWithoutBound() {
        // chaque NUL s'écrit sur 5 caractères : 3 NUL tiennent dans 15 caractères, le quatrième est caché
        let params = ApprovalParams(String(repeating: "\u{0}", count: 10), limit: 15)
        XCTAssertEqual(params.shown, String(repeating: #"\u{0}"#, count: 3))
        XCTAssertEqual(params.escaped, 3, "seuls les caractères montrés comptent")
        XCTAssertEqual(params.hidden, 7)
        XCTAssertEqual(params.total, 10)
    }

    func testTheCutIsMeasuredInUnicodeScalarsNotInBytes() {
        let params = ApprovalParams("éé😀😀😀", limit: 3)
        XCTAssertEqual(params.shown, "éé😀")
        XCTAssertEqual(params.hidden, 2)
        XCTAssertEqual(params.total, 5)
    }

    func testAnEmptyCommandShowsNothingAndChangesNothing() {
        let params = ApprovalParams("")
        XCTAssertEqual(params.shown, "")
        XCTAssertFalse(params.isChanged)
    }

    func testTheDefaultLimitKeepsTheSheetResponsiveOnA200000CharacterCommand() {
        let params = ApprovalParams(String(repeating: "0123456789abcdef", count: 12_500))
        XCTAssertEqual(params.total, 200_000)
        XCTAssertEqual(params.shown.count, ApprovalParams.limit)
        XCTAssertEqual(params.hidden, 200_000 - ApprovalParams.limit)
    }
}
