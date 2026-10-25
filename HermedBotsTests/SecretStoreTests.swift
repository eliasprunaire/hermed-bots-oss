import Security
import XCTest

final class SecretStoreTests: XCTestCase {
    private final class Items: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: Data] = [KeychainSecretStore.account: Data("legacy-test-key".utf8)]

        func account(_ query: CFDictionary) -> String {
            let query = query as NSDictionary
            XCTAssertEqual(query[kSecAttrService] as? String, KeychainSecretStore.service)
            XCTAssertEqual(query[kSecClass] as? String, kSecClassGenericPassword as String)
            return query[kSecAttrAccount] as! String
        }

        var store: KeychainSecretStore {
            KeychainSecretStore(copyMatching: { query, result in
                self.lock.withLock {
                    let account = self.account(query)
                    guard let value = self.values[account] else { return errSecItemNotFound }
                    result?.pointee = value as CFData
                    return errSecSuccess
                }
            }, update: { query, attributes in
                self.lock.withLock {
                    let account = self.account(query)
                    guard self.values[account] != nil else { return errSecItemNotFound }
                    self.values[account] = (attributes as NSDictionary)[kSecValueData] as? Data
                    return errSecSuccess
                }
            }, add: { query in
                self.lock.withLock {
                    let account = self.account(query)
                    XCTAssertNil(self.values[account])
                    XCTAssertEqual((query as NSDictionary)[kSecAttrAccessible] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
                    self.values[account] = (query as NSDictionary)[kSecValueData] as? Data
                    return errSecSuccess
                }
            })
        }
    }

    func testKeychainStoresUpdatesAndReadsEachProfileIndependently() throws {
        let items = Items()
        let store = items.store
        XCTAssertEqual(try store.apiKey(profile: "default"), "legacy-test-key")
        XCTAssertNil(try store.apiKey(profile: "cyber"))
        try store.setAPIKey("cyber-test-key", profile: "cyber")
        try store.setAPIKey("ia-test-key", profile: "ia")
        try store.setAPIKey("replacement-test-key", profile: "cyber")
        try store.setAPIKey("default-test-key", profile: "default")
        XCTAssertEqual(try store.apiKey(profile: "cyber"), "replacement-test-key")
        XCTAssertEqual(try store.apiKey(profile: "ia"), "ia-test-key")
        XCTAssertEqual(try store.apiKey(profile: "default"), "default-test-key")
        XCTAssertNil(try store.apiKey(profile: "missing"))
        XCTAssertNil(try store.apiKey(profile: "CYBER"))
        XCTAssertEqual(items.values[KeychainSecretStore.account], Data("legacy-test-key".utf8))
        XCTAssertEqual(items.values.count, 4)
    }

    func testKeychainReadErrorsNeverFallBackToTheLegacyKey() {
        let store = KeychainSecretStore(copyMatching: { _, _ in errSecInteractionNotAllowed })
        XCTAssertThrowsError(try store.apiKey(profile: "default"))
        XCTAssertThrowsError(try store.apiKey(profile: "cyber"))
    }

    func testKeychainWriteErrorsNeverAddAnotherEntry() {
        let store = KeychainSecretStore(update: { _, _ in errSecAuthFailed }, add: { _ in
            XCTFail("Un échec de mise à jour ne crée aucune entrée")
            return errSecSuccess
        })
        XCTAssertThrowsError(try store.setAPIKey("test-key", profile: "cyber"))
        let refused = KeychainSecretStore(update: { _, _ in errSecItemNotFound }, add: { _ in errSecInteractionNotAllowed })
        XCTAssertThrowsError(try refused.setAPIKey("test-key", profile: "cyber"))
    }
}
