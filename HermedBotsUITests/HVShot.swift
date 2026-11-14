import XCTest

/// Capture de la fenêtre pour la passe de vérification : joint l'image au xcresult et annonce `HV-SHOT <nom>`
/// Le runner XCUITest est sandboxé et ne peut pas écrire dans `$HV_SHOTS` : `hv-run.sh` exporte les pièces jointes
/// vers `shots/<nom>.png` et échoue si une capture annoncée manque
@MainActor
enum HVShot {
    /// Dossier de la passe donné par `hv-run.sh` (`$HV_EVIDENCE/shots`), nil hors passe de vérification ; `LaunchTests` s'en sert pour situer `run.log`
    static var directory: URL? {
        ProcessInfo.processInfo.environment["HV_SHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    @discardableResult
    static func capture(_ name: String, _ app: XCUIApplication) -> XCUIScreenshot {
        capture(name, app.windows.firstMatch)
    }

    @discardableResult
    static func capture(_ name: String, _ window: XCUIElement) -> XCUIScreenshot {
        collapseBeforeCapture()
        let screenshot = window.screenshot()
        print("HV-SHOT \(name)")
        XCTContext.runActivity(named: "capture \(name)") { activity in
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        return screenshot
    }

    /// Demande à l'app de réduire chaque sélection de champ à un point d'insertion, sans clic ni frappe
    static func collapseBeforeCapture() {
        final class Flag: @unchecked Sendable {
            var finished = false
        }
        let flag = Flag()
        let center = DistributedNotificationCenter.default()
        let observer = center.addObserver(
            forName: Notification.Name("com.hermedbots.hv.collapse-selection.done"),
            object: nil,
            queue: .main
        ) { _ in
            flag.finished = true
        }
        defer { center.removeObserver(observer) }
        center.postNotificationName(
            Notification.Name("com.hermedbots.hv.collapse-selection"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        let deadline = Date().addingTimeInterval(0.25)
        while !flag.finished, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }
}
