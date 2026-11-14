import XCTest
@testable import HermesAdapter

final class FooterCopyTests: XCTestCase {
    func testUnknownVersionHasASingleSpaceInFrenchAndEnglish() {
        XCTAssertEqual(FooterCopy.line("Version Hermes", "inconnue"), "Version Hermes inconnue")
        XCTAssertEqual(FooterCopy.line("Hermes version", "unknown"), "Hermes version unknown")
        XCTAssertFalse(FooterCopy.line("Version Hermes", "inconnue").contains("  "))
        XCTAssertFalse(FooterCopy.line("Hermes version", "unknown").contains("  "))
        XCTAssertFalse(FooterCopy.line("Version Hermes", "inconnue").hasPrefix(" "))
        XCTAssertFalse(FooterCopy.line("Version Hermes", "inconnue").hasSuffix(" "))
        XCTAssertFalse(FooterCopy.line("Hermes version", "unknown").hasPrefix(" "))
        XCTAssertFalse(FooterCopy.line("Hermes version", "unknown").hasSuffix(" "))
    }

    func testEmptyOrBlankTokenDropsTheGap() {
        XCTAssertEqual(FooterCopy.line("Version Hermes", ""), "Version Hermes")
        XCTAssertEqual(FooterCopy.line("Hermes version", "  "), "Hermes version")
        XCTAssertEqual(FooterCopy.line("Version Hermes", "\n\t"), "Version Hermes")
        XCTAssertEqual(FooterCopy.line("", "inconnue"), "inconnue")
        XCTAssertEqual(FooterCopy.line("  ", "unknown"), "unknown")
        XCTAssertFalse(FooterCopy.line("Version Hermes", "").hasSuffix(" "))
        XCTAssertFalse(FooterCopy.line("", "inconnue").hasPrefix(" "))
    }

    func testAlreadySpacedSegmentsCollapseToOneSpace() {
        XCTAssertEqual(FooterCopy.line("Version Hermes ", " inconnue"), "Version Hermes inconnue")
        XCTAssertEqual(FooterCopy.line("Version  Hermes", "  0.22.2  "), "Version Hermes 0.22.2")
        XCTAssertEqual(FooterCopy.line("Prêt", " · contexte 12 %"), "Prêt · contexte 12 %")
        XCTAssertEqual(FooterCopy.line("Ready"), "Ready")
        XCTAssertEqual(FooterCopy.line("  Port SSH 22  "), "Port SSH 22")
        XCTAssertEqual(
            FooterCopy.line("Hermes ne répond pas. Vérifiez la liaison puis réessayez."),
            "Hermes ne répond pas. Vérifiez la liaison puis réessayez."
        )
    }
}
