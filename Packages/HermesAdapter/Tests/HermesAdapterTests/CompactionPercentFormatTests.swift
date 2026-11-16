import Foundation
import XCTest

final class CompactionPercentFormatTests: XCTestCase {
    /// Catalogue de l'app, hors du paquet : la clé interpolée échappe le % en %%
    func testCatalogKeyEscapesThePercentAndFoundationRendersIt() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HermedBots/Resources/Localizable.xcstrings")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let strings = object["strings"] as! [String: Any]
        let key = " · contexte %lld %%"
        let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
        let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
        let english = try XCTUnwrap(localizations["en"] as? [String: Any])
        let unit = try XCTUnwrap(english["stringUnit"] as? [String: Any])
        let value = try XCTUnwrap(unit["value"] as? String)
        XCTAssertEqual(value, " · context %lld %%")
        XCTAssertEqual(String(format: key, CLongLong(12)), " · contexte 12 %")
        XCTAssertEqual(String(format: value, CLongLong(12)), " · context 12 %")
    }
}
