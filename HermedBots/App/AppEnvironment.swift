import AppSettings
import Foundation
import LoopGuard

struct AppEnvironment {
    var secrets: SecretStore
    /// Adresse directe de l'API, mode test seulement, quand aucun hôte SSH n'est donné (faux serveur sans sshd)
    let baseURL: URL?
    let ssh: SSHEndpoint?
    let isTestMode: Bool
    let defaults: UserDefaults
    var testHangMilliseconds = 0
    var testProfileLocks = false
    var testResumeScope: String?
    var testProfileTable: String?
    /// Mode test seulement : `HV_APPEARANCE=dark` force l'apparence sombre, pour la lane de rendu
    var testDarkAppearance = false
    /// Mode test seulement : `HV_WINDOW_SIZE=<largeur>x<hauteur>`, la taille du contenu de la fenêtre au lancement ; nil pour une valeur absente ou invalide
    var testWindowSize: CGSize?
    /// Mode test seulement : scène figée pour les captures XCUITest, sans réseau
    var testShotScene: String?
    /// Mode test seulement : `HV_NATIVE_PAUSE_NOTIFICATION=1` garde `UNUserNotificationCenter` pour la lane NativeNotifications
    var testNativePauseNotification = false

    /// Texte fixe du bandeau de pause en mode test : aucun appel à `UNUserNotificationCenter`
    static let testPauseNotification = "Notification de test."
    /// Hors mode test, le bandeau montre d'abord cette ligne pendant la demande d'autorisation macOS
    static let pauseNotificationPending = "Autorisation des notifications en attente."

    /// Le mode test refuse l'hôte factice `example-host`. Hors mode test, aucun hôte n'est refusé
    var refuseTestHost: Bool { isTestMode }

    /// Faux en mode test, sauf `HV_NATIVE_PAUSE_NOTIFICATION=1` : alors le produit (`LoopPauseNotifications`) est conservé
    var postsLoopPauseNotifications: Bool { !isTestMode || testNativePauseNotification }

    /// Première ligne de notification du bandeau : texte fixe en mode test, attente d'autorisation hors mode test
    var pauseNotificationLine: String {
        postsLoopPauseNotifications ? Self.pauseNotificationPending : Self.testPauseNotification
    }

    /// En mode test, ignore `product` et renvoie `testPauseNotification` ; hors mode test, conserve l'injection fournie
    func pauseNotifier(
        product: @escaping @Sendable (LoopGuard.Cause) async -> String
    ) -> @Sendable (LoopGuard.Cause) async -> String {
        if postsLoopPauseNotifications { return product }
        return { _ in Self.testPauseNotification }
    }

    /// Le mode test n'existe que dans un build Debug : une Release ignore `HV_TEST_MODE`, `HV_TEST_API_KEY`, `HV_TEST_API_KEYS`, `HV_TEST_SSH_KEY`, `HV_API_URL`, `HV_HANG_MS`, `HV_SSH_*` et `HV_NATIVE_PAUSE_NOTIFICATION`
    /// En mode test, `pauseNotifier` n'appelle pas `UNUserNotificationCenter`, sauf `HV_NATIVE_PAUSE_NOTIFICATION=1`
    /// `keychain` est une fabrique pour qu'un test prouve que le Trousseau n'est pas même construit en mode test
    static func resolve(_ environment: [String: String], defaults: UserDefaults = .standard, keychain: () -> SecretStore = { KeychainSecretStore() }) -> AppEnvironment {
        #if DEBUG
        if environment["HV_TEST_MODE"] == "1" {
            let host = environment["HV_SSH_HOST"] ?? ""
            let ssh = host.isEmpty ? nil : SSHEndpoint(host: host)
            return AppEnvironment(
                secrets: InMemorySecretStore(
                    apiKey: environment["HV_TEST_API_KEY"],
                    apiKeys: environment["HV_TEST_API_KEYS"].flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:]
                ),
                // l'adresse directe ne sert qu'à défaut de tunnel : avec un hôte SSH, rien ne contourne le tunnel
                baseURL: ssh == nil ? environment["HV_API_URL"].flatMap { URL(string: $0) } : nil,
                ssh: ssh,
                isTestMode: true,
                defaults: defaults,
                testHangMilliseconds: environment["HV_HANG_MS"].flatMap { Int($0) } ?? 0,
                testProfileLocks: environment["HV_PROFILE_LOCKS"] == "1",
                testResumeScope: environment["HV_RESUME_SCOPE"],
                testProfileTable: environment["HV_TEST_PROFILE_TABLE"],
                testDarkAppearance: environment["HV_APPEARANCE"] == "dark",
                testWindowSize: environment["HV_WINDOW_SIZE"].flatMap(windowSize),
                testShotScene: environment["HV_SHOT_SCENE"],
                testNativePauseNotification: environment["HV_NATIVE_PAUSE_NOTIFICATION"] == "1"
            )
        }
        #endif
        return AppEnvironment(secrets: keychain(), baseURL: nil, ssh: SSHEndpoint.stored(in: defaults), isTestMode: false, defaults: defaults)
    }

    /// « 760x520 » : deux entiers positifs séparés par un x
    private static func windowSize(_ value: String) -> CGSize? {
        let parts = value.split(separator: "x", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 2, let width = parts[0], let height = parts[1], width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }
}
