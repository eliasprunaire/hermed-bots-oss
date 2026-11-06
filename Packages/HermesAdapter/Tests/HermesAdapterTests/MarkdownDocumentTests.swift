import XCTest
@testable import HermesAdapter

final class MarkdownDocumentTests: XCTestCase {
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
        let document = MarkdownDocument.parse(source)
        XCTAssertTrue(document.hasTable)
        XCTAssertTrue(document.hasCodeBlock)
        XCTAssertFalse(document.visibleText.contains("**"))
        XCTAssertFalse(document.visibleText.contains("```"))
        XCTAssertTrue(document.visibleText.contains("default"))
        XCTAssertTrue(document.visibleText.contains("func render"))
        XCTAssertTrue(document.visibleText.contains("Gras et listes rendus"))
        XCTAssertFalse(document.visibleText.contains("| Profil"))
    }

    func testAPlainParagraphHasNoStarArtifacts() {
        let document = MarkdownDocument.parse("**gras** et *italique* et `code`.")
        XCTAssertEqual(MarkdownDocument.visible(paragraph(document)), "gras et italique et code.")
        XCTAssertFalse(document.visibleText.contains("*"))
        XCTAssertFalse(document.visibleText.contains("`"))
    }

    func testAnEmptySourceIsEmpty() {
        XCTAssertEqual(MarkdownDocument.parse("").blocks, [])
    }

    private func paragraph(_ document: MarkdownDocument) -> [MarkdownDocument.Inline] {
        guard case .paragraph(let inlines) = document.blocks.first else {
            XCTFail("paragraphe attendu")
            return []
        }
        return inlines
    }
}
