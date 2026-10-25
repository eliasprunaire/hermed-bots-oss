import AppSettings
import XCTest

// compilé dans le paquet de tests lui-même, sans l'app comme hôte : lancer ces tests ne démarre pas l'app, donc ne lit jamais le Trousseau
final class AppEnvironmentTests: XCTestCase {
    /// Échoue dès que quelqu'un le construit ou le lit
    private final class SpyKeychain: SecretStore {
        func apiKey(profile: String) throws -> String? {
            XCTFail("KeychainSecretStore appelé")
            return nil
        }

        func setAPIKey(_ key: String, profile: String) throws {
            XCTFail("KeychainSecretStore appelé")
        }

        func sshPrivateKey() throws -> String? {
            XCTFail("KeychainSecretStore appelé")
            return nil
        }
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "hd07-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private func spy() -> SecretStore {
        XCTFail("KeychainSecretStore construit")
        return SpyKeychain()
    }

    #if DEBUG
    func testTestModeInjectsTheInMemoryStoreAndNeverTouchesTheKeychain() throws {
        let environment = AppEnvironment.resolve(
            ["HV_TEST_MODE": "1", "HV_TEST_API_KEY": "cle-de-test-0123456789", "HV_API_URL": "http://127.0.0.1:18642"],
            keychain: spy
        )
        XCTAssertTrue(environment.secrets is InMemorySecretStore)
        XCTAssertEqual(try environment.secrets.apiKey(profile: "default"), "cle-de-test-0123456789")
        XCTAssertEqual(environment.baseURL, URL(string: "http://127.0.0.1:18642"))
    }

    func testProfileKeysStayIsolatedAndOnlyDefaultFallsBack() throws {
        var store = InMemorySecretStore(apiKey: "legacy-test-key", apiKeys: ["cyber": "cyber-test-key", "ia": "ia-test-key"])
        XCTAssertEqual(try store.apiKey(profile: "default"), "legacy-test-key")
        XCTAssertEqual(try store.apiKey(profile: "cyber"), "cyber-test-key")
        XCTAssertNil(try store.apiKey(profile: "missing"))
        try store.setAPIKey("replacement-test-key", profile: "cyber")
        try store.setAPIKey("default-test-key", profile: "default")
        XCTAssertEqual(try store.apiKey(profile: "cyber"), "replacement-test-key")
        XCTAssertEqual(try store.apiKey(profile: "ia"), "ia-test-key")
        XCTAssertEqual(try store.apiKey(profile: "default"), "default-test-key")
    }

    func testTestModeLoadsDistinctProfileKeysWithoutTheKeychain() throws {
        let environment = AppEnvironment.resolve([
            "HV_TEST_MODE": "1", "HV_TEST_API_KEY": "legacy-test-key",
            "HV_TEST_API_KEYS": #"{"cyber":"cyber-test-key","ia":"ia-test-key"}"#,
        ], keychain: spy)
        XCTAssertEqual(try environment.secrets.apiKey(profile: "cyber"), "cyber-test-key")
        XCTAssertEqual(try environment.secrets.apiKey(profile: "ia"), "ia-test-key")
        XCTAssertNil(try environment.secrets.apiKey(profile: "missing"))
    }

    func testProfileTableIsInjectedOnlyInTestMode() {
        let table = "Profile Model Gateway\nhv-bot-a model running"
        XCTAssertEqual(AppEnvironment.resolve(["HV_TEST_MODE": "1", "HV_TEST_PROFILE_TABLE": table], keychain: spy).testProfileTable, table)
        XCTAssertNil(AppEnvironment.resolve(["HV_TEST_PROFILE_TABLE": table], defaults: isolatedDefaults(), keychain: { SpyKeychain() }).testProfileTable)
    }

    func testInvalidProfileMapFailsClosed() throws {
        for value in ["invalid", #"{"cyber":123}"#] {
            let environment = AppEnvironment.resolve(["HV_TEST_MODE": "1", "HV_TEST_API_KEY": "legacy-test-key", "HV_TEST_API_KEYS": value], keychain: spy)
            XCTAssertNil(try environment.secrets.apiKey(profile: "cyber"))
        }
    }

    func testTestModeWithoutAKeyHasNoKeyAndDoesNotFallBackToTheKeychain() throws {
        let environment = AppEnvironment.resolve(["HV_TEST_MODE": "1"], keychain: spy)
        XCTAssertNil(try environment.secrets.apiKey(profile: "default"))
        XCTAssertNil(environment.baseURL)
    }

    func testTestModeReadsTheSSHEndpointAndTheKeyFromTheEnvironmentAndRefusesPersoHermes() throws {
        let environment = AppEnvironment.resolve(
            ["HV_TEST_MODE": "1", "HV_SSH_HOST": "host.example", "HV_SSH_USER": "hvssh", "HV_SSH_PORT": "2222", "HV_TEST_SSH_KEY": "cle-ssh-de-test"],
            defaults: isolatedDefaults(), keychain: spy
        )
        XCTAssertEqual(environment.ssh, SSHEndpoint(host: "host.example", user: "hvssh", port: 2222))
        XCTAssertEqual(try environment.secrets.sshPrivateKey(), "cle-ssh-de-test")
        XCTAssertTrue(environment.refusePersoHermes)
    }

    func testTheTunnelWinsOverTheDirectApiUrl() {
        let environment = AppEnvironment.resolve(
            ["HV_TEST_MODE": "1", "HV_SSH_HOST": "host.example", "HV_SSH_USER": "u", "HV_API_URL": "http://127.0.0.1:18642"],
            defaults: isolatedDefaults(), keychain: spy
        )
        XCTAssertNotNil(environment.ssh)
        XCTAssertNil(environment.baseURL, "avec un hôte SSH, l'app ne doit atteindre l'API que par le tunnel")
    }

    func testTestModeReadsTheMainThreadBlockToInjectAndIgnoresAValueThatIsNotANumber() {
        XCTAssertEqual(AppEnvironment.resolve(["HV_TEST_MODE": "1", "HV_HANG_MS": "400"], keychain: spy).testHangMilliseconds, 400)
        XCTAssertEqual(AppEnvironment.resolve(["HV_TEST_MODE": "1", "HV_HANG_MS": "abc"], keychain: spy).testHangMilliseconds, 0)
        XCTAssertEqual(AppEnvironment.resolve(["HV_TEST_MODE": "1"], keychain: spy).testHangMilliseconds, 0)
    }

    func testTestModeIgnoresTheStoredEndpoint() {
        let defaults = isolatedDefaults()
        SSHEndpoint(host: "host.example", user: "stored", port: 22).save(to: defaults)
        let environment = AppEnvironment.resolve(["HV_TEST_MODE": "1"], defaults: defaults, keychain: spy)
        XCTAssertNil(environment.ssh, "le mode test ne lit pas les réglages de l'utilisateur")
    }

    func testAnInvalidSSHPortFallsBackToThePort22() {
        let environment = AppEnvironment.resolve(["HV_TEST_MODE": "1", "HV_SSH_HOST": "host.example", "HV_SSH_USER": "u", "HV_SSH_PORT": "abc"], defaults: isolatedDefaults(), keychain: spy)
        XCTAssertEqual(environment.ssh?.port, 22)
    }

    func testOnlyTheValueOneEnablesTestMode() {
        for value in ["0", "true", "yes", "", " 1"] {
            var built = false
            let environment = AppEnvironment.resolve(["HV_TEST_MODE": value, "HV_API_URL": "http://127.0.0.1:18642"], keychain: {
                built = true
                return SpyKeychain()
            })
            XCTAssertTrue(built, "HV_TEST_MODE=\(value) devrait laisser le Trousseau actif")
            XCTAssertFalse(environment.secrets is InMemorySecretStore)
            XCTAssertNil(environment.baseURL)
        }
    }
    #else
    func testReleaseIgnoresTestModeTheTestKeyAndTheApiUrl() {
        var built = false
        let environment = AppEnvironment.resolve(
            ["HV_TEST_MODE": "1", "HV_TEST_API_KEY": "cle-de-test-0123456789", "HV_TEST_API_KEYS": #"{"cyber":"cyber-test-key"}"#, "HV_API_URL": "http://127.0.0.1:18642", "HV_SSH_HOST": "host.example", "HV_SSH_USER": "u", "HV_TEST_SSH_KEY": "k", "HV_TEST_PROFILE_TABLE": "ignored"],
            defaults: isolatedDefaults(),
            keychain: {
                built = true
                return SpyKeychain()
            }
        )
        XCTAssertTrue(built, "la Release utilise le Trousseau même avec HV_TEST_MODE=1")
        XCTAssertFalse(environment.secrets is InMemorySecretStore)
        XCTAssertNil(environment.baseURL)
        XCTAssertNil(environment.ssh, "la Release ignore HV_SSH_HOST")
        XCTAssertNil(environment.testProfileTable)
        XCTAssertFalse(environment.refusePersoHermes)
    }
    #endif

    func testWithoutTestModeTheKeychainIsUsedAndTheApiUrlIsIgnored() {
        var built = false
        let environment = AppEnvironment.resolve(["HV_API_URL": "http://127.0.0.1:18642"], keychain: {
            built = true
            return SpyKeychain()
        })
        XCTAssertTrue(built)
        XCTAssertFalse(environment.secrets is InMemorySecretStore)
        XCTAssertNil(environment.baseURL)
    }

    func testWithoutTestModeTheEndpointComesFromTheStoredSettingsAndTheEnvironmentIsIgnored() {
        let defaults = isolatedDefaults()
        SSHEndpoint(host: "perso.example", user: "operator", port: 2200).save(to: defaults)
        let environment = AppEnvironment.resolve(
            ["HV_SSH_HOST": "host.example", "HV_SSH_USER": "evil", "HV_SSH_PORT": "1", "HV_TEST_SSH_KEY": "x"],
            defaults: defaults, keychain: { SpyKeychain() }
        )
        XCTAssertEqual(environment.ssh, SSHEndpoint(host: "perso.example", user: "operator", port: 2200))
        XCTAssertFalse(environment.refusePersoHermes, "perso-hermes est la cible réelle du produit")
        XCTAssertFalse(environment.secrets is InMemorySecretStore)
    }

    func testWithoutTestModeNoMainThreadBlockIsInjected() {
        let environment = AppEnvironment.resolve(["HV_HANG_MS": "400"], defaults: isolatedDefaults(), keychain: { SpyKeychain() })
        XCTAssertEqual(environment.testHangMilliseconds, 0)
    }

    func testWithoutAStoredHostThereIsNoTunnelToOpen() {
        let environment = AppEnvironment.resolve([:], defaults: isolatedDefaults(), keychain: { SpyKeychain() })
        XCTAssertNil(environment.ssh)
    }

    func testSavingThenReadingGivesTheSameEndpoint() {
        let defaults = isolatedDefaults()
        XCTAssertNil(SSHEndpoint.stored(in: defaults))
        let endpoint = SSHEndpoint(host: "host.example", user: "u", port: 2022)
        endpoint.save(to: defaults)
        XCTAssertEqual(SSHEndpoint.stored(in: defaults), endpoint)
    }
}
