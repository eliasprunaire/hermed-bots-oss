import XCTest
import AppSettings

final class ToolbarCapsuleGapTests: XCTestCase {
    func testTheRenderedGapIsThirteenPointsInLightAndDarkStandardAndLargeText() {
        for dark in [false, true] {
            for largeText in [false, true] {
                let gap = ToolbarCapsuleGap.resolved(dark: dark, largeText: largeText)
                XCTAssertEqual(gap, 13, "dark=\(dark) largeText=\(largeText)")
                let extra = ToolbarCapsuleGap.extraLeadingPadding(dark: dark, largeText: largeText)
                XCTAssertEqual(extra, 6, "dark=\(dark) largeText=\(largeText)")
            }
        }
    }
}
