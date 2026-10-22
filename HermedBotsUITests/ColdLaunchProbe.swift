import XCTest

/// Sonde de perf de HD-07 : un lancement à froid, du lancement à la première réponse de l'API affichée
/// Avec `HV_SSH_HOST` l'app passe par le tunnel, sinon par `HV_API_URL` en connexion directe : le même fichier tourne sur le trunk et sur le head
/// Chaque exécution mesure un lancement ; `perf.sh` en enchaîne cinq de chaque côté, en alternance
@MainActor
final class ColdLaunchProbe: XCTestCase {
    func testOneColdLaunchToTheFirstApiReply() throws {
        let environment = ProcessInfo.processInfo.environment
        // sans lane : `xcodebuild test` seul ne doit pas échouer faute d'un Hermes à mesurer
        try XCTSkipIf(environment["HV_SSH_HOST"] == nil && environment["HV_API_URL"] == nil, "ni HV_SSH_HOST ni HV_API_URL : pas de Hermes à mesurer")
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(fr)"]
        app.launchEnvironment["HV_TEST_MODE"] = "1"
        for name in ["HV_TEST_API_KEY", "HV_TEST_API_KEYS"] { app.launchEnvironment[name] = environment[name] }
        let mode: String
        if let host = environment["HV_SSH_HOST"] {
            mode = "tunnel"
            app.launchEnvironment["HV_SSH_HOST"] = host
            app.launchEnvironment["HV_SSH_USER"] = environment["HV_SSH_USER"] ?? "hvssh"
            app.launchEnvironment["HV_TEST_SSH_KEY"] = environment["HV_TEST_SSH_KEY"]
        } else {
            mode = "direct"
            app.launchEnvironment["HV_API_URL"] = environment["HV_API_URL"]
        }
        let start = ContinuousClock.now
        app.launch()
        let version = app.descendants(matching: .any).matching(identifier: AccessibilityID.statusVersion.rawValue).firstMatch
        var shown = ""
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if version.exists {
                shown = (version.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? version.label
                if !["…", "inconnue", ""].contains(shown) { break }
            }
            usleep(20_000)
        }
        let elapsed = ContinuousClock.now - start
        let milliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        print("HV-PERF07 mode=\(mode) ms=\(milliseconds) version=\(shown)")
        app.terminate()
        XCTAssertFalse(["…", "inconnue", ""].contains(shown), "aucune réponse de l'API affichée en 30 s")
    }
}
