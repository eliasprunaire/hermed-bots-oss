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
                stderrLimit: 65_536
            )
        } catch SpawnError.timedOut {
            throw SSHFailure.unreachable("délai dépassé")
        } catch {
            throw SSHFailure.unreachable("ssh ne démarre pas")
        }
        guard output.status == 0 else { throw SSHFailure.unknownAlias }
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
        let unknown = isUnknownAlias(alias: alias, debug: debug)
        return SSHConnectionPreview(
            alias: alias,
            hostname: hostname,
            user: user,
            port: port,
            hasRelay: hasRelay,
            identity: identity,
            identityPresent: present,
            isUnknownAlias: unknown
        )
    }

    /// Un alias est inconnu s'il n'a pas de bloc Host ou Match qui le nomme (stderr de `ssh -G -vv`)
    /// Les valeurs de `ssh -G` ne comptent pas : un `Host *` qui fixe un User, un Port ou une identité les donne à n'importe quel nom
    /// Un bloc Host ou Match qui ne change aucune valeur reste un alias valide
    /// Un bloc qui vaut pour tout nom (`Host *`, `Match all`, `Match user *`, `Match host *`) ne nomme pas l'alias
    static func isUnknownAlias(alias: String, debug: String) -> Bool {
        !(hostBlock(matches: alias, debug: debug) || matchBlock(matches: alias, debug: debug))
    }

    /// `debug2: checking match for '<critères>' host … originally …` puis `match found` (`-vv`)
    /// Seul un critère `host` ou `originalhost` propre à l'alias compte : les autres critères ne nomment aucun hôte
    static func matchBlock(matches alias: String, debug: String) -> Bool {
        var names = false
        for line in debug.split(whereSeparator: \.isNewline) {
            let text = String(line)
            if text.contains("checking match for") {
                names = false
                if let start = text.range(of: "checking match for '"), let end = text.range(of: "' host ", options: .backwards), start.upperBound <= end.lowerBound {
                    names = criteria(String(text[start.upperBound..<end.lowerBound]), name: alias)
                }
            } else if names, text.localizedCaseInsensitiveContains("match found") {
                return true
            }
        }
        return false
    }

    /// `debug1: … Applying options for <pattern>` : un motif propre qui couvre l'alias
    static func hostBlock(matches alias: String, debug: String) -> Bool {
        for line in debug.split(whereSeparator: \.isNewline) {
            let text = String(line)
            guard let range = text.range(of: "Applying options for ") else { continue }
            if ownPattern(String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces), matches: alias) { return true }
        }
        return false
    }

    /// Un critère `host` ou `originalhost` non nié dont la liste contient un motif propre qui couvre l'alias
    private static func criteria(_ text: String, name alias: String) -> Bool {
        let tokens = words(in: text)
        var index = 0
        while index < tokens.count {
            var keyword = tokens[index].lowercased()
            index += 1
            let negated = keyword.hasPrefix("!")
            if negated { keyword.removeFirst() }
            if ["all", "canonical", "final"].contains(keyword) { continue }
            guard index < tokens.count else { break }
            let argument = tokens[index]
            index += 1
            if !negated, keyword == "host" || keyword == "originalhost",
               argument.split(separator: ",").contains(where: { ownPattern(String($0), matches: alias) }) { return true }
        }
        return false
    }

    /// Un motif non nié, qui n'est pas `*` seul, et qui couvre l'alias
    private static func ownPattern(_ pattern: String, matches alias: String) -> Bool {
        !pattern.hasPrefix("!") && pattern.contains { $0 != "*" } && glob(pattern, matches: alias)
    }

    /// Découpe comme OpenSSH : espaces, tabulations et `=` séparent, les guillemets groupent, un `#` hors guillemets ouvre un commentaire
    /// shortcut: les échappements `\"` ne sont pas lus, un exec qui en contient dérègle le découpage de ses mots, à revoir si un cas réel apparaît
    private static func words(in text: String) -> [String] {
        var words: [String] = []
        var word = ""
        var quote: Character?
        var open = false
        for character in text {
            if let current = quote {
                if character == current { quote = nil } else { word.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                open = true
            } else if character == " " || character == "\t" || character == "=" {
                if open { words.append(word) }
                word = ""
                open = false
            } else if character == "#", !open {
                return words
            } else {
                word.append(character)
                open = true
            }
        }
        if open { words.append(word) }
        return words
    }

    private static func glob(_ pattern: String, matches value: String) -> Bool {
        var regex = "^"
        for character in pattern {
            switch character {
            case "*": regex += ".*"
            case "?": regex += "."
            case ".", "[", "]", "{", "}", "(", ")", "+", "^", "$", "|", "\\":
                regex += "\\\(character)"
            default:
                regex += String(character)
            }
        }
        regex += "$"
        return value.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil
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
