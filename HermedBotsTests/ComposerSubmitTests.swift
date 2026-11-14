import XCTest

// compilé dans le paquet de tests lui-même, sans l'app comme hôte
final class ComposerSubmitTests: XCTestCase {
    func testARefusedReturnCollapsesTheSelectionToTheEndOfTheDraft() {
        XCTAssertEqual(ComposerSubmit.collapsedRange(of: ""), NSRange(location: 0, length: 0))
        XCTAssertEqual(ComposerSubmit.collapsedRange(of: "suite en attente"), NSRange(location: 16, length: 0))
        XCTAssertEqual(ComposerSubmit.collapsedRange(of: "é"), NSRange(location: 1, length: 0))
        let long = String(repeating: "é", count: 100)
        XCTAssertEqual(ComposerSubmit.collapsedRange(of: long), NSRange(location: 100, length: 0))
    }
}
