import XCTest
@testable import HermesAdapter

final class MarkdownVisibleTextTests: XCTestCase {
    func testBoldListTableAndCodeLeaveNoRawMarkers() {
        let source = """
        # Comparaison
        Le profil **default** produit plus de structure ; *tiny* reste plat.
        | Profil | Modèle | Style |
        | --- | --- | --- |
        | default | claude-sonnet-5-5 | titres, listes, tableaux |
        | tiny | deepseek-v4.1-flash | texte court |
        - Gras et listes rendus
        - Tableau natif
        ```
        func render(_ md: String) -> AttributedString
        ```
        """
        let visible = MarkdownVisibleText.of(source)
        XCTAssertFalse(visible.contains("**"))
        XCTAssertFalse(visible.contains("```"))
        XCTAssertTrue(visible.contains("default"))
        XCTAssertTrue(visible.contains("func render"))
        XCTAssertTrue(visible.contains("Gras et listes rendus"))
        XCTAssertFalse(visible.contains("| Profil"))
        XCTAssertFalse(visible.contains("*tiny*"))
    }

    func testAPlainParagraphHasNoStarArtifacts() {
        let visible = MarkdownVisibleText.of("**gras** et *italique* et `code`.")
        XCTAssertEqual(visible, "gras et italique et code.")
        XCTAssertFalse(visible.contains("*"))
        XCTAssertFalse(visible.contains("`"))
    }

    func testStarBulletsLeaveNoRawAsterisks() {
        let visible = MarkdownVisibleText.of("* premier\n* **gras** dans la puce\n* *italique*")
        XCTAssertFalse(visible.contains("*"))
        XCTAssertTrue(visible.contains("premier"))
        XCTAssertTrue(visible.contains("gras dans la puce"))
        XCTAssertTrue(visible.contains("italique"))
    }

    func testALongResponseKeepsNoRawStars() {
        let block = "**gras** et *italique* et * puce\n"
        var source = ""
        while source.utf16.count <= 10_000 { source += block }
        XCTAssertGreaterThan(source.count, 10_000)
        let visible = MarkdownVisibleText.of(source)
        XCTAssertFalse(visible.contains("*"), "une réponse de plus de 10 000 caractères laisse des étoiles")
        XCTAssertTrue(visible.contains("gras"))
        XCTAssertTrue(visible.contains("italique"))
        XCTAssertTrue(visible.contains("puce"))
    }

    func testStreamingAnUnclosedMarkerLeavesNoRawStars() {
        let chunks = [
            "Début **gr",
            "Début **gras",
            "Début **gras** et *it",
            "Début **gras** et *italique",
            "* une puce encore ouverte **fort",
        ]
        for chunk in chunks {
            let prepared = MarkdownVisibleText.prepared(chunk)
            let visible = MarkdownVisibleText.of(chunk)
            XCTAssertFalse(visible.contains("*"), "flux « \(chunk) » laisse \(visible)")
            XCTAssertFalse(MarkdownVisibleText.of(prepared).contains("*"))
        }
    }

    func testAnEmptySourceIsEmpty() {
        XCTAssertEqual(MarkdownVisibleText.of(""), "")
        XCTAssertEqual(MarkdownVisibleText.prepared(""), "")
    }
}
