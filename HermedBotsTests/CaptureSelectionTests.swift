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

    func testAHelpTagIsHitOnTheControlAndMissedAtTheTitleBar() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let gear = NSButton(frame: NSRect(x: 360, y: 8, width: 28, height: 24))
        gear.toolTip = "Réglages"
        let bot = NSButton(frame: NSRect(x: 20, y: 80, width: 200, height: 80))
        bot.toolTip = "hv-bot-b"
        content.addSubview(gear)
        content.addSubview(bot)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.contentView = content

        XCTAssertEqual(CaptureSelection.helpTag(at: NSPoint(x: 374, y: 20), in: window), "Réglages")
        XCTAssertEqual(CaptureSelection.helpTag(at: NSPoint(x: 120, y: 120), in: window), "hv-bot-b")
        XCTAssertNil(CaptureSelection.helpTag(at: CaptureSelection.neutralPoint(in: window), in: window))
    }

    func testDismissingATooltipPanelLeavesTheFirstResponder() {
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 48))
        editor.string = "État inconnu"
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 48),
            styleMask: .titled,
            backing: .buffered,
            defer: true
        )
        window.contentView = editor
        window.makeFirstResponder(editor)

        let panel = ToolTipPanel(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 24),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.orderFront(nil)
        XCTAssertTrue(CaptureSelection.isTooltipWindow(panel))
        XCTAssertTrue(panel.isVisible)

        CaptureSelection.dismissOpenToolTips()

        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(window.firstResponder === editor)
    }

    private final class ToolTipPanel: NSPanel {}
}
