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
    let isUnknownAlias: Bool
    let hasMatchBlock: Bool
    let isUnreadable: Bool

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
    var stderr: String = ""
}

protocol SSHConfigResolving: Sendable {
    func dump(alias: String, invocation: SSHInvocation) async throws -> SSHConfigDump
}

/// `/usr/bin/ssh -G -vv <arguments du lancement>` : stdout = config aplatie ; stderr nomme Host et Match (`match found` n'apparaît qu'à `-vv`)
struct SystemSSHConfigResolver: SSHConfigResolving {
    let environment: [String: String]
    /// `-F` : un test seulement ; l'app résout toujours avec la config de l'utilisateur
    let configFile: String?

    init(environment: [String: String] = ProcessInfo.processInfo.environment, configFile: String? = nil) {
        self.environment = environment
        self.configFile = configFile
    }

    static func arguments(alias: String, invocation: SSHInvocation, configFile: String? = nil) -> [String] {
        ["-G", "-vv"] + (configFile.map { ["-F", $0] } ?? []) + SSHTunnelConfig.arguments(invocation, alias: alias)
    }

    func dump(alias: String, invocation: SSHInvocation) async throws -> SSHConfigDump {
        let output: Spawn.Output
        do {
            output = try await Spawn.runGuarded(
                "/usr/bin/ssh",
                Self.arguments(alias: alias, invocation: invocation, configFile: configFile),
                environment: SSHChildEnvironment.make(environment),
                timeout: .seconds(8),
                stderrLimit: SSHConfig.logLimit
            )
        } catch SpawnError.timedOut {
            throw SSHFailure.unreachable("délai dépassé")
        } catch {
            throw SSHFailure.unreachable("ssh ne démarre pas")
        }
        // ssh sort en erreur sur une config qu'il ne lit pas (guillemet non fermé, option inconnue, argument manquant)
        guard output.status == 0 else { throw SSHFailure.unreadableConfig }
        return SSHConfigDump(stdout: output.stdout, stderr: output.stderr)
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
            debug: dump.stderr,
            alias: alias,
            localUser: localUser,
            filesExist: filesExist,
            authSock: authSock
        )
    }

    static func parse(
        _ dump: String,
        debug: String = "",
        alias: String,
        localUser: String,
        filesExist: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        authSock: String? = nil
    ) -> SSHConnectionPreview {
        let values = dictionary(from: dump)
        let hostname = first(values["hostname"]) ?? alias
        let user = first(values["user"]) ?? localUser
        let port = Int(first(values["port"]) ?? "") ?? 22
        // `none` supprime un relais hérité : toute autre valeur de ProxyJump ou de ProxyCommand est un relais
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
            identityPresent: present,
            isUnknownAlias: !namesAlias(alias, debug: debug),
            hasMatchBlock: debug.contains("checking match for"),
            isUnreadable: debug.utf8.count >= logLimit || debug.contains("matched no files")
        )
    }

    /// Taille maximale gardée du journal `ssh -G -vv` : au-delà, une ligne Match peut manquer
    static let logLimit = 65_536

    /// Un alias est connu si un bloc `Host` l'écrit tel quel : `debug1: <fichier> line <n>: Applying options for <motif>`
    /// Les valeurs de `ssh -G` ne comptent pas : un `Host *` qui fixe un User, un Port ou une identité les donne à n'importe quel nom
    /// ssh n'écrit que le premier motif de la ligne Host qui couvre l'alias : `Host * alias` n'est pas lu comme un nom
    /// Une ligne qui n'a pas exactement cette forme ne nomme rien : l'alias est refusé
    static func namesAlias(_ alias: String, debug: String) -> Bool {
        debug.split(whereSeparator: \.isNewline).contains { line in
            guard let match = line.wholeMatch(of: #/debug1: .* line [0-9]+: Applying options for (\S+)/#) else { return false }
            let pattern = match.1
            // `*`, `?` et `!` sont les seuls caractères spéciaux d'un motif Host ; ssh compare sans ignorer la casse
            return !pattern.contains { "*?!".contains($0) } && String(pattern) == alias
        }
    }

    private static func kind(certificates: [String], agent: String?, identityFiles: [String], authSock: String?) -> SSHIdentityKind {
        if !certificates.isEmpty { return .certificate }
        // `IdentityAgent none` désactive l'agent, la socket de la session comprise
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
    static func config(from preview: SSHConnectionPreview, refusePersoHermes: Bool, remotePort: Int = 8642) throws -> SSHTunnelConfig {
        // l'app n'interprète aucun critère Match et refuse ce qu'elle ne lit pas avec certitude : en cas de doute, refus
        if preview.isUnreadable { throw SSHFailure.unreadableConfig }
        if preview.hasMatchBlock { throw SSHFailure.matchBlockRefused }
        // un relais mène à un hôte que l'app ne sait pas valider : tout alias qui en contient un est refusé, en mode test comme hors mode test
        if preview.hasRelay { throw SSHFailure.relayRefused }
        let config = try SSHTunnelConfig(
            alias: preview.alias,
            hostname: preview.hostname,
            user: preview.user,
            sshPort: preview.port,
            remotePort: remotePort,
            refusePersoHermes: refusePersoHermes
        )
        if preview.isUnknownAlias { throw SSHFailure.unknownAlias }
        return config
    }
}

/// Une seule connexion en cours : `begin` invalide toute résolution en vol, y compris un refus local (vide, invalide, perso-hermes)
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
        refusePersoHermes: Bool,
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
        if refusePersoHermes, trimmed.lowercased().contains("perso-hermes") {
            refused(.forbiddenHost, nil)
            return
        }
        guard SSHTunnelConfig.isAlias(trimmed) else {
            refused(.invalidHost, nil)
            return
        }
        task = Task { await resolve(alias: trimmed, id: id, refusePersoHermes: refusePersoHermes, opened: opened, refused: refused) }
    }

    private func resolve(
        alias: String,
        id: Int,
        refusePersoHermes: Bool,
        opened: @MainActor (SSHTunnelConfig, SSHConnectionPreview) -> Void,
        refused: @MainActor (SSHFailure, SSHConnectionPreview?) -> Void
    ) async {
        var preview: SSHConnectionPreview?
        do {
            var tunnel: (config: SSHTunnelConfig, preview: SSHConnectionPreview)?
            // chaque lancement de ssh est validé avec ses propres arguments ; le tunnel (le premier) fournit l'aperçu
            for invocation in SSHInvocation.allCases {
                let dump = try await resolver.dump(alias: alias, invocation: invocation)
                guard id == generation, !Task.isCancelled else { return }
                let next = SSHConfig.parse(dump, alias: alias, localUser: localUser, authSock: authSock)
                preview = next
                let config = try SSHConnectionPlanner.config(from: next, refusePersoHermes: refusePersoHermes)
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
