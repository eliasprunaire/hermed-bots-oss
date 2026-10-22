import Foundation
import XCTest

/// Les routes de contrôle du faux serveur (`/_hv/*`), pour un test qui pose ses propres événements
enum FakeServer {
    static func apiKey(for path: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let raw = environment["HV_TEST_API_KEYS"], let keys = try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8)) {
            let parts = path.split(separator: "/")
            return keys[parts.first == "p" && parts.count > 1 ? String(parts[1]) : "default"]
        }
        return environment["HV_TEST_API_KEY"]
    }

    /// Retire les événements injectés ; sans effet sur une instance Hermes réelle, qui n'a pas cette route
    static func reset() {
        post("/_hv/reset", [:])
    }

    /// Pose le modèle de chaque profil dans la table que le faux serveur sert à la place de `hermes profile list` (HD-10) : `reset()` la rétablit
    /// La fixture est le relevé de l'OrbStack, où tous les profils ont le même modèle : sans ce réglage, le sélecteur n'aurait qu'une option
    static func setProfileModels(_ models: [String: String]) {
        post("/_hv/profile-models", models)
    }

    /// Un autre client de Hermes verrouille le modèle d'un fil : la vraie route `set_model`, avec la clé de test quand il y en a une
    static func lockModel(profile: String, session: String, model: String) {
        post("/p/\(profile)/api/sessions/\(session)/model", ["model": model], authorized: true)
    }

    static func cut(seconds: Int) {
        post("/_hv/cut", ["seconds": String(seconds)])
    }

    static func configure(mode: String = "normal", drop: String = "set_model", profiles: [String]? = nil) {
        var body: [String: Any] = ["mode": mode, "drop": drop]
        if let profiles { body["profiles"] = profiles }
        XCTAssertTrue(post("/_hv/config", body), "Le faux serveur refuse la configuration du test")
    }

    @discardableResult
    private static func post(_ path: String, _ body: [String: Any], authorized: Bool = false) -> Bool {
        guard let base = ProcessInfo.processInfo.environment["HV_API_URL"], let url = URL(string: base + path) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.httpMethod = "POST"
        if !body.isEmpty { request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        if authorized, let key = apiKey(for: path) { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var accepted = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            accepted = (response as? HTTPURLResponse)?.statusCode == 200
            done.signal()
        }.resume()
        return done.wait(timeout: .now() + 20) == .success && accepted
    }
}
