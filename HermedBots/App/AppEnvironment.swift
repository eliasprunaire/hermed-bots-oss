import AppSettings
import Foundation

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

    /// Le mode test refuse l'hôte factice `example-host`. Hors mode test, aucun hôte n'est refusé.
    var refuseTestHost: Bool { isTestMode }

    /// Le mode test n'existe que dans un build Debug : une Release ignore `HV_TEST_MODE`, `HV_TEST_API_KEY`, `HV_TEST_API_KEYS`, `HV_TEST_SSH_KEY`, `HV_API_URL`, `HV_HANG_MS` et `HV_SSH_*`
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
                testProfileTable: environment["HV_TEST_PROFILE_TABLE"]
            )
        }
        #endif
        return AppEnvironment(secrets: keychain(), baseURL: nil, ssh: SSHEndpoint.stored(in: defaults), isTestMode: false, defaults: defaults)
    }
}
