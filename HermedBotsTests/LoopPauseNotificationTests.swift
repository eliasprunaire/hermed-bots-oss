import Darwin
import LoopGuard
import XCTest

#if DEBUG
final class LoopPauseNotificationTests: XCTestCase {
    func testPostInTestModeReturnsTheAuthorizationFakeWithoutMacOS() async {
        let previous = getenv("HV_TEST_MODE").map { String(cString: $0) }
        setenv("HV_TEST_MODE", "1", 1)
        defer {
            if let previous {
                setenv("HV_TEST_MODE", previous, 1)
            } else {
                unsetenv("HV_TEST_MODE")
            }
        }
        let status = await LoopPauseNotifications.shared.post(cause: .repeatedToolCall(count: 3))
        XCTAssertEqual(status, LoopPauseNotifications.testAuthorizationGranted)
        XCTAssertTrue(status.localizedCaseInsensitiveContains("autorisation"))
        XCTAssertFalse(status.contains("Notification de test."))
        XCTAssertFalse(status.contains("remise par macOS"))
    }
}
#endif
