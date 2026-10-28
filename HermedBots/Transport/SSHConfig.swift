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
    let hasRelay: Bool
    let identity: SSHIdentityKind
    let identityPresent: Bool

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

struct SSHConfigDump: Equatable, Sendable {
    var stdout: String
}

protocol SSHConfigResolving: Sendable {
    /// `agentSocket` : l'agent temporaire du lancement ; `ssh -G` le reçoit comme le lancement, par `SSH_AUTH_SOCK` et par `-o IdentityAgent`
    func dump(alias: String, invocation: SSHInvocation, agentSocket: String?) async throws -> SSHConfigDump
    func dumpAPIKey(alias: String, profile: String, agentSocket: String?) async throws -> SSHConfigDump
}

extension SSHConfigResolving {
    func dump(alias: String, invocation: SSHInvocation) async throws -> SSHConfigDump {
        try await dump(alias: alias, invocation: invocation, agentSocket: nil)
    }

    func dumpAPIKey(alias: String, profile: String) async throws -> SSHConfigDump {
        try await dumpAPIKey(alias: alias, profile: profile, agentSocket: nil)
    }
}

struct SystemSSHConfigResolver: SSHConfigResolving {
    let environment: [String: String]
    let configFile: String?

    init(environment: [String: String] = ProcessInfo.processInfo.environment, configFile: String? = nil) {
        self.environment = environment
        self.configFile = configFile
    }

    static func arguments(alias: String, invocation: SSHInvocation, configFile: String? = nil, agentSocket: String? = nil) -> [String] {
        ["-G"] + (configFile.map { ["-F", $0] } ?? []) + launch(SSHTunnelConfig.arguments(invocation, alias: alias), agentSocket: agentSocket)
    }

    static func apiKeyArguments(alias: String, profile: String, configFile: String? = nil, agentSocket: String? = nil) throws -> [String] {
        ["-G"] + (configFile.map { ["-F", $0] } ?? []) + launch(try SSHTunnelConfig.apiKeyLaunchArguments(alias: alias, profile: profile), agentSocket: agentSocket)
    }

    private static func launch(_ arguments: [String], agentSocket: String?) -> [String] {
        agentSocket.map { SSHTunnelConfig.withIdentityAgent(arguments, socket: $0) } ?? arguments
    }

    func dump(alias: String, invocation: SSHInvocation, agentSocket: String?) async throws -> SSHConfigDump {
        let output: Spawn.Output
        do {
            output = try await Spawn.runGuarded(
                "/usr/bin/ssh",
                Self.arguments(alias: alias, invocation: invocation, configFile: configFile, agentSocket: agentSocket),
                environment: SSHChildEnvironment.make(environment, agentSocket: agentSocket),
                timeout: .seconds(8)
            )
        } catch SpawnError.timedOut {
            throw SSHFailure.unreachable("délai dépassé")
        } catch {
            throw SSHFailure.unreachable("ssh ne démarre pas")
        }
        guard output.status == 0 else { throw SSHFailure.unreadableConfig }
        return SSHConfigDump(stdout: output.stdout)
    }

    func dumpAPIKey(alias: String, profile: String, agentSocket: String?) async throws -> SSHConfigDump {
        let output: Spawn.Output
        do {
            output = try await Spawn.runGuarded(
                "/usr/bin/ssh",
                try Self.apiKeyArguments(alias: alias, profile: profile, configFile: configFile, agentSocket: agentSocket),
                environment: SSHChildEnvironment.make(environment, agentSocket: agentSocket),
                timeout: .seconds(8)
            )
        } catch SpawnError.timedOut {
            throw SSHFailure.unreachable("délai dépassé")
        } catch let failure as SSHFailure {
            throw failure
        } catch is HermesProfileName {
            throw SSHFailure.invalidHost
        } catch {
            throw SSHFailure.unreachable("ssh ne démarre pas")
        }
        guard output.status == 0 else { throw SSHFailure.unreadableConfig }
        return SSHConfigDump(stdout: output.stdout)
    }
}

enum SSHConfig {
    private static let defaultIdentityNames: Set<String> = [
        "id_rsa", "id_ecdsa", "id_ecdsa_sk", "id_ed25519", "id_ed25519_sk", "id_xmss", "id_dsa",
    ]

    /// Analyse la sortie de `ssh -G`. Les chemins restent hors des libellés affichés.
    static func parse(
        _ dump: SSHConfigDump,
        alias: String,
        localUser: String,
        filesExist: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        authSock: String? = nil
    ) -> SSHConnectionPreview {
        parse(
            dump.stdout,
            alias: alias,
            localUser: localUser,
            filesExist: filesExist,
            authSock: authSock
        )
    }

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
        let hasRelay = ["proxyjump", "proxycommand"].contains { first(values[$0]).map { !isNone($0) } ?? false }
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
        return SSHConnectionPreview(
            alias: alias,
            hostname: hostname,
            user: user,
            port: port,
            hasRelay: hasRelay,
            identity: identity,
            identityPresent: present
        )
    }

    private static func kind(certificates: [String], agent: String?, identityFiles: [String], authSock: String?) -> SSHIdentityKind {
        if !certificates.isEmpty { return .certificate }
        if let agent, isNone(agent) { return .file }
        let customFiles = identityFiles.contains { !defaultIdentityNames.contains(URL(fileURLWithPath: $0).lastPathComponent) }
        if let agent, agent != "SSH_AUTH_SOCK" { return .agent }
        if customFiles { return .file }
        if agent != nil { return .agent }
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
            if let agent, agent != "SSH_AUTH_SOCK" { return filesExist(expand(agent)) }
            if let authSock, !authSock.isEmpty { return filesExist(authSock) }
            return false
        }
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
    static func config(from preview: SSHConnectionPreview, refuseTestHost: Bool, remotePort: Int = 8642, matching tunnel: SSHTunnelConfig? = nil) throws -> SSHTunnelConfig {
        if preview.hasRelay { throw SSHFailure.relayRefused }
        let next = try SSHTunnelConfig(
            alias: preview.alias,
            hostname: preview.hostname,
            user: preview.user,
            sshPort: preview.port,
            remotePort: remotePort,
            refuseTestHost: refuseTestHost
        )
        if let tunnel, !sameRoute(next, tunnel) { throw SSHFailure.routeMismatch }
        return next
    }

    static func sameRoute(_ left: SSHTunnelConfig, _ right: SSHTunnelConfig) -> Bool {
        left.hostname.caseInsensitiveCompare(right.hostname) == .orderedSame
            && left.user == right.user
            && left.sshPort == right.sshPort
    }
}

/// Une seule connexion en cours : `begin` invalide toute résolution en vol, y compris un refus local (vide, invalide, example-host)
@MainActor
final class SSHConnector {
    private var generation = 0
    private var task: Task<Void, Never>?
    private let resolver: any SSHConfigResolving
    private let localUser: String
    private let authSock: String?

    init(
        resolver: any SSHConfigResolving,
        localUser: String = NSUserName(),
        authSock: String? = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
    ) {
        self.resolver = resolver
        self.localUser = localUser
        self.authSock = authSock
    }

    func begin(
        alias: String,
        refuseTestHost: Bool,
        opened: @escaping @MainActor (SSHTunnelConfig, SSHConnectionPreview) -> Void,
        refused: @escaping @MainActor (SSHFailure, SSHConnectionPreview?) -> Void
    ) {
        generation += 1
        let id = generation
        task?.cancel()
        task = nil
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            refused(.invalidHost, nil)
            return
        }
        if refuseTestHost, SSHTunnelConfig.isForbiddenTestHost(trimmed) {
            refused(.forbiddenHost, nil)
            return
        }
        guard SSHTunnelConfig.isAlias(trimmed) else {
            refused(.invalidHost, nil)
            return
        }
        task = Task { await resolve(alias: trimmed, id: id, refuseTestHost: refuseTestHost, opened: opened, refused: refused) }
    }

    private func resolve(
        alias: String,
        id: Int,
        refuseTestHost: Bool,
        opened: @MainActor (SSHTunnelConfig, SSHConnectionPreview) -> Void,
        refused: @MainActor (SSHFailure, SSHConnectionPreview?) -> Void
    ) async {
        var preview: SSHConnectionPreview?
        do {
            var tunnel: (config: SSHTunnelConfig, preview: SSHConnectionPreview)?
            for invocation in SSHInvocation.allCases {
                let dump = try await resolver.dump(alias: alias, invocation: invocation)
                guard id == generation, !Task.isCancelled else { return }
                let next = SSHConfig.parse(dump, alias: alias, localUser: localUser, authSock: authSock)
                preview = preview ?? next
                let config = try SSHConnectionPlanner.config(from: next, refuseTestHost: refuseTestHost)
                tunnel = tunnel ?? (config, next)
            }
            guard id == generation, !Task.isCancelled, let tunnel else { return }
            opened(tunnel.config, tunnel.preview)
        } catch is CancellationError {
            return
        } catch {
            guard id == generation, !Task.isCancelled else { return }
            refused(error as? SSHFailure ?? .invalidHost, preview)
        }
    }
}
