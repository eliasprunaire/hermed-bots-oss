import Foundation
import Security

/// Là où l'app lit les clés API Hermes ; l'identité SSH vient de la config et de l'agent de l'utilisateur
protocol SecretStore: Sendable {
    func apiKey(profile: String) throws -> String?
    mutating func setAPIKey(_ key: String, profile: String) throws
}

/// Magasin du mode test (`HV_TEST_MODE=1`) : il ne touche jamais le Trousseau
struct InMemorySecretStore: SecretStore {
    private let key: String?
    private var apiKeys: [String: String]

    init(apiKey: String?, apiKeys: [String: String] = [:]) {
        key = apiKey
        self.apiKeys = apiKeys
    }

    func apiKey(profile: String) throws -> String? { apiKeys[profile] ?? (profile == "default" ? key : nil) }

    mutating func setAPIKey(_ key: String, profile: String) throws { apiKeys[profile] = key }
}

struct KeychainError: Error, CustomStringConvertible {
    let status: OSStatus

    var description: String {
        "Trousseau : \(SecCopyErrorMessageString(status, nil) as String? ?? "erreur \(status)")"
    }
}

/// Clés dans le Trousseau de l'utilisateur ; la première saisie réelle reste manuelle (A3)
struct KeychainSecretStore: SecretStore {
    static let service = "com.hermedbots.HermedBots"
    static let account = "hermes-api-key"
    private let copyMatching: @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    private let update: @Sendable (CFDictionary, CFDictionary) -> OSStatus
    private let add: @Sendable (CFDictionary) -> OSStatus

    init(
        copyMatching: @escaping @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = { SecItemCopyMatching($0, $1) },
        update: @escaping @Sendable (CFDictionary, CFDictionary) -> OSStatus = { SecItemUpdate($0, $1) },
        add: @escaping @Sendable (CFDictionary) -> OSStatus = { SecItemAdd($0, nil) }
    ) {
        self.copyMatching = copyMatching
        self.update = update
        self.add = add
    }

    func apiKey(profile: String) throws -> String? {
        if let key = try read(account: Self.apiAccount(profile)) { return key }
        return profile == "default" ? try read(account: Self.account) : nil
    }

    func setAPIKey(_ key: String, profile: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.apiAccount(profile),
        ]
        let value = Data(key.utf8)
        let status = update(query as CFDictionary, [kSecValueData: value] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = value
            item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = add(item as CFDictionary)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess { throw KeychainError(status: status) }
    }

    private static func apiAccount(_ profile: String) -> String { "\(account):\(profile)" }

    private func read(account: String) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        switch copyMatching(query as CFDictionary, &item) {
        case errSecSuccess: return (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
        case errSecItemNotFound: return nil
        case let status: throw KeychainError(status: status)
        }
    }
}
