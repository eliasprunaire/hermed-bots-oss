import Foundation
import XCTest

final class CompactionPercentFormatTests: XCTestCase {
    /// Catalogue de l'app, hors du paquet : la clé interpolée échappe le % en %%
    func testCatalogKeyEscapesThePercentAndFoundationRendersIt() throws {
        let url = try XCTUnwrap(
            catalogURL(startingAt: URL(fileURLWithPath: #filePath)),
            "HermedBots/Resources/Localizable.xcstrings"
        )
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

    /// Remonte depuis le fichier source jusqu'au catalogue, hors du paquet Swift.
    private func catalogURL(startingAt file: URL) -> URL? {
        var dir = file.deletingLastPathComponent()
        let relative = "HermedBots/Resources/Localizable.xcstrings"
        while true {
            let candidate = dir.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path {
                return nil
            }
            dir = parent
        }
    }
}
