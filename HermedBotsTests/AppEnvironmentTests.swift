import AppSettings
import XCTest

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

    func testProfileKeysStayIsolatedWithoutFallingBackToDefault() throws {
        var store = InMemorySecretStore(apiKey: "legacy-test-key", apiKeys: ["cyber": "cyber-test-key", "ia": "ia-test-key"])
        XCTAssertEqual(try store.apiKey(profile: "default"), "legacy-test-key")
        XCTAssertEqual(try store.apiKey(profile: "cyber"), "cyber-test-key")
        XCTAssertNil(try store.apiKey(profile: "missing"))
        try store.setAPIKey("replacement-test-key", profile: "cyber")
        try store.setAPIKey("default-test-key", profile: "default")
        XCTAssertEqual(try store.apiKey(profile: "cyber"), "replacement-test-key")
        XCTAssertEqual(try store.apiKey(profile: "ia"), "ia-test-key")
        XCTAssertEqual(try store.apiKey(profile: "default"), "default-test-key")
        XCTAssertNil(try store.resolvedAPIKey(profile: "missing"))
        XCTAssertEqual(try store.resolvedAPIKey(profile: "cyber"), "replacement-test-key")
        XCTAssertEqual(try store.resolvedAPIKey(profile: "default"), "default-test-key")
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

    func testTestModeReadsTheSSHAliasFromTheEnvironmentAndRefusesPersoHermes() throws {
        let environment = AppEnvironment.resolve(
            ["HV_TEST_MODE": "1", "HV_SSH_HOST": "lab.invalid", "HV_SSH_USER": "ignored", "HV_SSH_PORT": "2222", "HV_TEST_SSH_KEY": "cle-ssh-de-test"],
            defaults: isolatedDefaults(), keychain: spy
        )
        XCTAssertEqual(environment.ssh, SSHEndpoint(host: "lab.invalid"))
        XCTAssertTrue(environment.refusePersoHermes)
        XCTAssertTrue(environment.secrets is InMemorySecretStore)
    }

    func testTheTunnelWinsOverTheDirectApiUrl() {
        let environment = AppEnvironment.resolve(
            ["HV_TEST_MODE": "1", "HV_SSH_HOST": "lab.invalid", "HV_SSH_USER": "u", "HV_API_URL": "http://127.0.0.1:18642"],
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
        SSHEndpoint(host: "lab.invalid").save(to: defaults)
        let environment = AppEnvironment.resolve(["HV_TEST_MODE": "1"], defaults: defaults, keychain: spy)
        XCTAssertNil(environment.ssh, "le mode test ne lit pas les réglages de l'utilisateur")
    }

    func testTestModeIgnoresUserAndPortEnvironmentOverrides() {
        let environment = AppEnvironment.resolve(["HV_TEST_MODE": "1", "HV_SSH_HOST": "lab.invalid", "HV_SSH_USER": "u", "HV_SSH_PORT": "abc"], defaults: isolatedDefaults(), keychain: spy)
        XCTAssertEqual(environment.ssh, SSHEndpoint(host: "lab.invalid"))
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
        SSHEndpoint(host: "lab.invalid").save(to: defaults)
        let environment = AppEnvironment.resolve(
            ["HV_SSH_HOST": "other.invalid", "HV_SSH_USER": "evil", "HV_SSH_PORT": "1", "HV_TEST_SSH_KEY": "x"],
            defaults: defaults, keychain: { SpyKeychain() }
        )
        XCTAssertEqual(environment.ssh, SSHEndpoint(host: "lab.invalid"))
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
        let endpoint = SSHEndpoint(host: "lab.invalid")
        endpoint.save(to: defaults)
        XCTAssertEqual(SSHEndpoint.stored(in: defaults), endpoint)
    }
}
