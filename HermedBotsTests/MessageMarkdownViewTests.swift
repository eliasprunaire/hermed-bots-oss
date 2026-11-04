import HermesAdapter
import XCTest

final class MessageMarkdownViewTests: XCTestCase {
    func testARemoteMarkdownImageBecomesAltTextAndLeavesNoFetchableURL() {
        let source = "Voir ![schéma](https://cdn.example.invalid/plot.png) ici."
        let prepared = MarkdownVisibleText.prepared(source)
        XCTAssertFalse(prepared.contains("https://"))
        XCTAssertFalse(prepared.contains("cdn.example.invalid"))
        XCTAssertEqual(MarkdownVisibleText.of(source), "Voir schéma ici.")
    }
}
