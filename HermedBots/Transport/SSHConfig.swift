import AppSettings
import CryptoKit
import Foundation

/// Ce que `ssh -G` a retenu pour un alias, sans aucun secret
enum SSHIdentityKind: Equatable, Sendable {
    case agent
    case certificate
    case file
    case executable

    var label: String {
        switch self {
        case .agent: String(localized: "agent SSH")
        case .certificate: String(localized: "certificat")
        case .file: String(localized: "fichier")
        case .executable: String(localized: "gérée par l'exécutable")
        }
    }

    var launchKind: SSHLaunchIdentityKind {
        switch self {
        case .agent: .agent
        case .certificate: .certificate
        case .file: .file
        case .executable: .executable
        }
    }

    init(_ launch: SSHLaunchIdentityKind) {
        switch launch {
        case .agent: self = .agent
        case .certificate: self = .certificate
        case .file: self = .file
        case .executable: self = .executable
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
    let usesExternalIdentityAgent: Bool
    let identityAgentValue: String?
    let sessionKind: SSHLaunchIdentityKind
    let sessionPresent: Bool
    /// Au moins une source d'identité existe (certificat, fichier de clé, IdentityAgent ou agent de session) : ssh les essaie toutes, `identityPresent` n'en juge qu'une
    let anySessionIdentityPresent: Bool

    var identityPresentLabel: String {
        if identity == .certificate {
            return identityPresent ? String(localized: "présent") : String(localized: "absent")
        }
        return identityPresent ? String(localized: "présente") : String(localized: "absente")
    }

    var identityPresentTitle: String {
        identity == .certificate ? String(localized: "Certificat") : String(localized: "Clé publique")
    }

    func matchingLaunch(mode: SSHAuthMode, keyCommandSet: Bool) -> SSHConnectionPreview {
        let launch = SSHLaunchIdentity.overlay(
            mode: mode,
            sessionKind: sessionKind,
            sessionPresent: sessionPresent,
            keyCommandSet: keyCommandSet,
            hasExternalIdentityAgent: usesExternalIdentityAgent
        )
        return SSHConnectionPreview(
            alias: alias,
            hostname: hostname,
            user: user,
            port: port,
            hasRelay: hasRelay,
            identity: SSHIdentityKind(launch.kind),
            identityPresent: launch.present,
            usesExternalIdentityAgent: usesExternalIdentityAgent,
            identityAgentValue: identityAgentValue,
            sessionKind: sessionKind,
            sessionPresent: sessionPresent,
            anySessionIdentityPresent: anySessionIdentityPresent
        )
    }

    /// Le mode agent temporaire n'utilise que sa commande de clé ou l'IdentityAgent externe ; les autres modes laissent ssh essayer toute source
    func canAuthenticate(mode: SSHAuthMode) -> Bool {
        mode == .ephemeralAgent ? identityPresent : anySessionIdentityPresent
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
        authSock: String? = nil,
        environment: [String: String] = SSHChildEnvironment.make(),
        localHost: String = localHostName()
    ) -> SSHConnectionPreview {
        parse(
            dump.stdout,
            alias: alias,
            localUser: localUser,
            filesExist: filesExist,
            authSock: authSock,
            environment: environment,
            localHost: localHost
        )
    }

    static func parse(
        _ dump: String,
        alias: String,
        localUser: String,
        filesExist: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        authSock: String? = nil,
        environment: [String: String] = SSHChildEnvironment.make(),
        localHost: String = localHostName()
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
        // `authSock` est le socket de la session : il remplace celui de l'environnement de l'app
        var sshEnvironment = environment
        sshEnvironment["SSH_AUTH_SOCK"] = authSock.flatMap { $0.isEmpty ? nil : $0 }
        let jump = first(values["proxyjump"]).flatMap { isNone($0) ? nil : $0 } ?? ""
        let expansion = PathExpansion(
            alias: alias,
            hostname: hostname,
            port: port,
            user: user,
            localUser: localUser,
            localHost: localHost,
            jump: jump,
            hostKeyAlias: first(values["hostkeyalias"]),
            environment: sshEnvironment
        )
        let present = identityPresent(
            kind: identity,
            certificates: certificates,
            identityFiles: identityFiles,
            agent: agent,
            authSock: authSock,
            expansion: expansion,
            filesExist: filesExist
        )
        return SSHConnectionPreview(
            alias: alias,
            hostname: hostname,
            user: user,
            port: port,
            hasRelay: hasRelay,
            identity: identity,
            identityPresent: present,
            usesExternalIdentityAgent: SSHLaunchIdentity.identityAgentIsExternal(agent),
            identityAgentValue: agent,
            sessionKind: identity.launchKind,
            sessionPresent: present,
            anySessionIdentityPresent: [SSHIdentityKind.certificate, .file, .agent].contains {
                identityPresent(kind: $0, certificates: certificates, identityFiles: identityFiles, agent: agent, authSock: authSock, expansion: expansion, filesExist: filesExist)
            }
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
        expansion: PathExpansion,
        filesExist: (String) -> Bool
    ) -> Bool {
        switch kind {
        case .certificate:
            return certificates.contains { expansion($0).map(filesExist) ?? false }
        case .file:
            return identityFiles.contains { path in
                guard let expanded = expansion(path) else { return false }
                return filesExist(expanded) || filesExist(expanded + ".pub")
            }
        case .agent:
            if let agent, isNone(agent) { return false }
            if let agent {
                return identityAgentPath(agent, environment: expansion.environment).map(filesExist) ?? false
            }
            if let authSock, !authSock.isEmpty { return filesExist(authSock) }
            return false
        case .executable:
            // le dump n'en produit jamais : seul le mode Exécutable le pose, et l'exécutable choisit l'identité
            return true
        }
    }

    /// Le socket que ssh ouvre pour la valeur `IdentityAgent` du dump ; `nil` quand la variable lue est absente
    /// `ssh -G` a déjà développé `~`, les jetons, `%%` et `${VAR}` (ssh.c, avant l'impression du dump) : la valeur est le chemin, sans seconde expansion
    /// Restent `SSH_AUTH_SOCK` et `$VAR`, que ssh lit après le dump dans son environnement et prend tels quels, sans les développer
    private static func identityAgentPath(_ value: String, environment: [String: String]) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name = identityAgentEnvironmentName(trimmed) else { return trimmed }
        return environment[name]
    }

    /// `${VAR}` n'en est pas une : ssh -G l'a développé, et ce qui reste est un chemin (ssh teste `$` puis un caractère autre que `{`)
    private static func identityAgentEnvironmentName(_ value: String) -> String? {
        if value == "SSH_AUTH_SOCK" { return value }
        guard value.hasPrefix("$"), !value.hasPrefix("${") else { return nil }
        let name = String(value.dropFirst())
        return name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) == nil ? nil : name
    }

    /// Nom d'hôte local tel que ssh le lit pour les jetons `%l` et `%L`
    static func localHostName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Ce que ssh fait d'un chemin `IdentityFile` ou `CertificateFile` avant de l'ouvrir : `~`, jetons `%x` (ssh_config(5), TOKENS), puis `${VAR}` de son environnement
    /// `ssh -G` laisse ces deux champs tels quels ; il développe lui-même `IdentityAgent`, dont la valeur du dump ne passe jamais ici
    /// Le résultat est `nil` quand ssh ignore le réglage (jeton inconnu, `%` ou `${` isolés, variable absente)
    private struct PathExpansion {
        let alias: String
        let hostname: String
        let port: Int
        let user: String
        let localUser: String
        let localHost: String
        let jump: String
        let hostKeyAlias: String?
        let environment: [String: String]

        func callAsFunction(_ path: String) -> String? {
            let characters = Array(SSHConfig.expand(path))
            var result = ""
            var index = 0
            while index < characters.count {
                let character = characters[index]
                if character == "%" {
                    guard index + 1 < characters.count, let value = token(characters[index + 1]) else { return nil }
                    result += value
                    index += 2
                } else if character == "$", index + 1 < characters.count, characters[index + 1] == "{" {
                    guard let close = characters[(index + 2)...].firstIndex(of: "}"),
                          let value = environment[String(characters[(index + 2)..<close])] else { return nil }
                    result += value
                    index = close + 1
                } else {
                    result.append(character)
                    index += 1
                }
            }
            return result
        }

        private func token(_ key: Character) -> String? {
            switch key {
            case "%": "%"
            case "C": Insecure.SHA1.hash(data: Data((localHost + hostname + String(port) + user + jump).utf8)).map { String(format: "%02x", $0) }.joined()
            case "d": SSHConfig.expand("~")
            case "h": hostname
            case "i": String(getuid())
            case "j": jump
            case "k": hostKeyAlias ?? alias
            case "L": localHost.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? localHost
            case "l": localHost
            case "n": alias
            case "p": String(port)
            case "r": user
            case "u": localUser
            default: nil
            }
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

    fileprivate static func expand(_ path: String) -> String {
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
        authMode: SSHAuthMode = .sessionAgent,
        keyCommandSet: Bool = false,
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
        task = Task {
            await resolve(
                alias: trimmed,
                id: id,
                refuseTestHost: refuseTestHost,
                authMode: authMode,
                keyCommandSet: keyCommandSet,
                opened: opened,
                refused: refused
            )
        }
    }

    private func resolve(
        alias: String,
        id: Int,
        refuseTestHost: Bool,
        authMode: SSHAuthMode,
        keyCommandSet: Bool,
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
                    .matchingLaunch(mode: authMode, keyCommandSet: keyCommandSet)
                preview = preview ?? next
                let config = try SSHConnectionPlanner.config(from: next, refuseTestHost: refuseTestHost)
                // le mode Exécutable apporte sa propre identité ; sinon une seule source existante suffit
                if authMode != .wrapper, !next.canAuthenticate(mode: authMode) { throw SSHFailure.noIdentity }
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
