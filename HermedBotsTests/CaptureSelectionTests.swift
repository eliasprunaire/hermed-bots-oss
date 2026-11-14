import AppKit
import XCTest

// compilé dans le paquet de tests lui-même, sans l'app comme hôte
@MainActor
final class CaptureSelectionTests: XCTestCase {
    func testAFullSelectionCollapsesToAZeroLengthInsertionPointWithoutResigningFirstResponder() {
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 48))
        editor.string = "État inconnu"
        let selected = NSRange(location: 0, length: (editor.string as NSString).length)
        XCTAssertGreaterThan(selected.length, 0)
        editor.setSelectedRange(selected)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 48),
            styleMask: .titled,
            backing: .buffered,
            defer: true
        )
        window.contentView = editor
        window.makeFirstResponder(editor)

        CaptureSelection.apply(to: editor)

        XCTAssertEqual(editor.selectedRange().length, 0)
        XCTAssertEqual(editor.selectedRange(), ComposerSubmit.collapsedRange(of: editor.string))
        XCTAssertTrue(window.firstResponder === editor)
    }
}
