import Foundation

/// Ce que `ssh -G` a retenu pour un alias, sans aucun secret
enum SSHIdentityKind: Equatable, Sendable {
    case agent
    case certificate
    case file

    var label: String {
        switch self {
        case .agent: String(localized: "agent SSH")
        case .certificate: String(localized: "certificat")
        case .file: String(localized: "fichier")
        }
    }
}

struct SSHConnectionPreview: Equatable, Sendable {
    let alias: String
    let hostname: String
    let user: String
    let port: Int
    let jumpCount: Int
    let identity: SSHIdentityKind
    let identityPresent: Bool
    let isUnknownAlias: Bool

    var jumpLabel: String {
        let unit = jumpCount <= 1 ? String(localized: "saut") : String(localized: "sauts")
        return "\(jumpCount) \(unit)"
    }

    var identityPresentLabel: String {
        if identity == .certificate {
            return identityPresent ? String(localized: "présent") : String(localized: "absent")
        }
        return identityPresent ? String(localized: "présente") : String(localized: "absente")
    }

    var identityPresentTitle: String {
        identity == .certificate ? String(localized: "Certificat") : String(localized: "Clé publique")
    }
}

protocol SSHConfigResolving: Sendable {
    func dump(alias: String) async throws -> String
}

/// `/usr/bin/ssh -G <alias>` avec la config par défaut, Include compris
struct SystemSSHConfigResolver: SSHConfigResolving {
    let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    func dump(alias: String) async throws -> String {
        let output: Spawn.Output
        do {
            output = try await Spawn.run(
                "/usr/bin/ssh",
                ["-G", alias],
                environment: SSHChildEnvironment.make(environment),
                timeout: .seconds(8)
            )
        } catch SpawnError.timedOut {
            throw SSHFailure.unreachable("délai dépassé")
        } catch {
            throw SSHFailure.unreachable("ssh ne démarre pas")
        }
        guard output.status == 0 else { throw SSHFailure.unknownAlias }
        return output.stdout
    }
}

enum SSHConfig {
    private static let defaultIdentityNames: Set<String> = [
        "id_rsa", "id_ecdsa", "id_ecdsa_sk", "id_ed25519", "id_ed25519_sk", "id_xmss", "id_dsa",
    ]

    /// Analyse la sortie de `ssh -G`. Les chemins restent hors des libellés affichés.
    static func parse(
        _ dump: String,
        alias: String,
        localUser: String,
        filesExist: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        authSock: String? = nil
    ) -> SSHConnectionPreview {
        let values = dictionary(from: dump)
        let hostname = first(values["hostname"]) ?? alias
        let user = first(values["user"]) ?? localUser
        let port = Int(first(values["port"]) ?? "") ?? 22
        let jumps = proxyJumpCount(first(values["proxyjump"]))
        let certificates = (values["certificatefile"] ?? []).filter { !isNone($0) }
        let identityFiles = values["identityfile"] ?? []
        let agent = first(values["identityagent"])
        let identity = kind(certificates: certificates, agent: agent, identityFiles: identityFiles, authSock: authSock)
        let present = identityPresent(
            kind: identity,
            certificates: certificates,
            identityFiles: identityFiles,
            agent: agent,
            authSock: authSock,
            filesExist: filesExist
        )
        let unknown = isUnknownAlias(
            alias: alias,
            hostname: hostname,
            port: port,
            user: user,
            localUser: localUser,
            jumps: jumps,
            proxyCommand: first(values["proxycommand"]),
            certificates: certificates,
            agent: agent,
            identityFiles: identityFiles
        )
        return SSHConnectionPreview(
            alias: alias,
            hostname: hostname,
            user: user,
            port: port,
            jumpCount: jumps,
            identity: identity,
            identityPresent: present,
            isUnknownAlias: unknown
        )
    }

    /// `ssh -G` rend l'alias tel quel et le port 22 quand aucun bloc Host ne correspond
    static func isUnknownAlias(
        alias: String,
        hostname: String,
        port: Int,
        user: String,
        localUser: String,
        jumps: Int,
        proxyCommand: String?,
        certificates: [String],
        agent: String?,
        identityFiles: [String]
    ) -> Bool {
        guard hostname.caseInsensitiveCompare(alias) == .orderedSame, port == 22 else { return false }
        if user != localUser { return false }
        if jumps > 0 { return false }
        if let proxyCommand, !isNone(proxyCommand) { return false }
        if !certificates.isEmpty { return false }
        if let agent, !isNone(agent), agent != "SSH_AUTH_SOCK" { return false }
        return identityFiles.allSatisfy { defaultIdentityNames.contains(URL(fileURLWithPath: $0).lastPathComponent) }
    }

    private static func kind(certificates: [String], agent: String?, identityFiles: [String], authSock: String?) -> SSHIdentityKind {
        if !certificates.isEmpty { return .certificate }
        let customFiles = identityFiles.contains { !defaultIdentityNames.contains(URL(fileURLWithPath: $0).lastPathComponent) }
        if let agent, !isNone(agent), agent != "SSH_AUTH_SOCK" { return .agent }
        if customFiles { return .file }
        if let agent, !isNone(agent) { return .agent }
        if let authSock, !authSock.isEmpty { return .agent }
        return .file
    }

    private static func identityPresent(
        kind: SSHIdentityKind,
        certificates: [String],
        identityFiles: [String],
        agent: String?,
        authSock: String?,
        filesExist: (String) -> Bool
    ) -> Bool {
        switch kind {
        case .certificate:
            return certificates.contains { filesExist(expand($0)) }
        case .file:
            return identityFiles.contains { path in
                let expanded = expand(path)
                return filesExist(expanded) || filesExist(expanded + ".pub")
            }
        case .agent:
            if let agent, !isNone(agent), agent != "SSH_AUTH_SOCK" { return filesExist(expand(agent)) }
            if let authSock, !authSock.isEmpty { return filesExist(authSock) }
            return false
        }
    }

    private static func proxyJumpCount(_ value: String?) -> Int {
        guard let value, !isNone(value) else { return 0 }
        return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !isNone(String($0)) }.count
    }

    private static func dictionary(from dump: String) -> [String: [String]] {
        var values: [String: [String]] = [:]
        for line in dump.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let space = text.firstIndex(of: " ") else { continue }
            let key = String(text[..<space]).lowercased()
            let value = String(text[text.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            values[key, default: []].append(value)
        }
        return values
    }

    private static func first(_ values: [String]?) -> String? {
        values?.first { !$0.isEmpty }
    }

    private static func isNone(_ value: String) -> Bool {
        value.caseInsensitiveCompare("none") == .orderedSame
    }

    private static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

enum SSHConnectionPlanner {
    static func config(from preview: SSHConnectionPreview, refusePersoHermes: Bool, remotePort: Int = 8642) throws -> SSHTunnelConfig {
        if preview.isUnknownAlias { throw SSHFailure.unknownAlias }
        return try SSHTunnelConfig(
            alias: preview.alias,
            hostname: preview.hostname,
            user: preview.user,
            sshPort: preview.port,
            remotePort: remotePort,
            refusePersoHermes: refusePersoHermes
        )
    }
}
