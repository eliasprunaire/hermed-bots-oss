import AppKit
import Darwin
import Foundation
import Observation
import os

// MARK: - Configuration

/// Pourquoi le tunnel ne s'ouvre pas ou s'est fermé
/// Seul `unreachable` donne lieu à une réouverture : une clé refusée ou un hôte changé ne se règle pas en réessayant
enum SSHFailure: Error, Equatable, Sendable {
    case forbiddenHost
    case relayRefused
    case invalidHost
    case invalidPort
    case unknownAlias
    case matchBlockRefused
    case unreadableConfig
    case agentLockedOrEmpty(String)
    case certificateExpired(String)
    case wrongKey(String)
    case hostKeyChanged(String)
    case unreachable(String)

    var retries: Bool {
        if case .unreachable = self { true } else { false }
    }

    static func classify(stderr: String) -> SSHFailure {
        let text = stderr
        let last = lastLine(text)
        if text.localizedCaseInsensitiveContains("agent refused operation")
            || text.contains("Could not open a connection to your authentication agent") {
            return .agentLockedOrEmpty(last)
        }
        if text.localizedCaseInsensitiveContains("certificate invalid")
            || text.localizedCaseInsensitiveContains("certificate expired")
            || text.localizedCaseInsensitiveContains("certificate has expired") {
            return .certificateExpired(last)
        }
        if text.contains("Permission denied") { return .wrongKey(last) }
        if text.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || text.contains("Host key verification failed") { return .hostKeyChanged(last) }
        return .unreachable(last)
    }

    private static func lastLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
}

extension SSHFailure {
    var message: String {
        switch self {
        case .forbiddenHost: String(localized: "Cet hôte est refusé en mode test.")
        case .relayRefused: String(localized: "Cet alias passe par un relais (ProxyJump ou ProxyCommand). Hermed Bots le refuse : utilise un alias qui se connecte directement à l'hôte.")
        case .invalidHost: String(localized: "L'alias SSH n'est pas valide.")
        case .invalidPort: String(localized: "Le port n'est pas valide.")
        case .unknownAlias: String(localized: "Cet alias SSH est inconnu.")
        case .matchBlockRefused: String(localized: "Ta config SSH contient un bloc Match. Hermed Bots ne l'interprète pas et refuse l'alias : remplace le bloc Match par des blocs Host.")
        case .unreadableConfig: String(localized: "Hermed Bots ne lit pas cette config SSH avec certitude : erreur de syntaxe, Include sans fichier ou journal trop long. L'alias est refusé.")
        case .agentLockedOrEmpty(let detail): sshLine(detail) ?? String(localized: "L'agent SSH est verrouillé ou vide.")
        case .certificateExpired(let detail): sshLine(detail) ?? String(localized: "Le certificat SSH a expiré.")
        case .wrongKey(let detail): sshLine(detail) ?? String(localized: "Le serveur refuse l'identité SSH. Vérifie la config de l'alias, puis réessaie.")
        case .hostKeyChanged(let detail): sshLine(detail) ?? String(localized: "La clé de l'hôte a changé. Le tunnel reste fermé.")
        case .unreachable(let reason): reason.isEmpty ? String(localized: "Hôte injoignable.") : String(localized: "Hôte injoignable : \(reason)")
        }
    }

    private func sshLine(_ detail: String) -> String? {
        let line = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
    }
}

struct RemoteCommandFailure: Error, Equatable, Sendable {
    let status: Int32
    let detail: String
}

/// Les quatre lancements de `/usr/bin/ssh` par l'app (les trois cas ci-dessous, plus `apiKeyArguments`)
/// Un bloc `Match sessiontype none` ou `Match command …` ne vaut que pour l'un des trois cas : chacun est résolu avec ses arguments
enum SSHInvocation: CaseIterable, Sendable {
    case tunnel
    case profileList
    case profileLocks
}

/// Là où le tunnel se connecte et ce qu'il redirige : un port local vers `127.0.0.1:remotePort` de l'hôte
/// `alias` est le seul argument d'hôte passé à ssh ; `hostname` et `user` viennent de `ssh -G`
struct SSHTunnelConfig: Equatable, Sendable {
    let alias: String
    let hostname: String
    let user: String
    let sshPort: Int
    let remotePort: Int

    /// `refusePersoHermes` est vrai en mode test : aucune connexion de test ne doit viser perso-hermes comme alias ou hôte résolu
    init(alias: String, hostname: String, user: String, sshPort: Int = 22, remotePort: Int = 8642, refusePersoHermes: Bool) throws {
        if refusePersoHermes {
            let route = [alias, hostname]
            if route.contains(where: { $0.lowercased().contains("perso-hermes") }) {
                throw SSHFailure.forbiddenHost
            }
        }
        guard Self.isAlias(alias) else { throw SSHFailure.invalidHost }
        guard Self.isHostname(hostname) else { throw SSHFailure.invalidHost }
        guard (1...65535).contains(sshPort), (1...65535).contains(remotePort) else { throw SSHFailure.invalidPort }
        self.alias = alias
        self.hostname = hostname
        self.user = user
        self.sshPort = sshPort
        self.remotePort = remotePort
    }

    /// Les arguments de `ssh` : l'alias, jamais `-F`, `-i`, `-l` ni `-p`
    func arguments(localPort: Int) -> [String] {
        Self.arguments(.tunnel, alias: alias, localPort: localPort, remotePort: remotePort)
    }

    /// Les arguments de la lecture de la liste des profils (décision S6)
    func profileListArguments() -> [String] {
        Self.arguments(.profileList, alias: alias)
    }

    /// Les arguments de la détection de Hermes Desktop
    func profileLocksArguments() -> [String] {
        Self.arguments(.profileLocks, alias: alias)
    }

    /// Les arguments de la lecture de `API_SERVER_KEY` d'un profil
    /// La commande est écrite ici et non passée en paramètre : aucun appelant ne peut en lancer une autre
    func apiKeyArguments(profile: String) throws -> [String] {
        Self.common([]) + [alias] + HermesAPIKey.remoteCommand(profile: try HermesAPIKey.validate(profile))
    }

    /// Une seule définition par lancement : `ssh -G` reçoit les mêmes arguments pour évaluer les mêmes blocs `Match`
    /// Les ports ne servent qu'au tunnel ; `ssh -G` ne lie rien
    static func arguments(_ invocation: SSHInvocation, alias: String, localPort: Int = 1, remotePort: Int = 8642) -> [String] {
        switch invocation {
        case .tunnel: common(["-N"]) + ["-L", "127.0.0.1:\(localPort):127.0.0.1:\(remotePort)", alias]
        case .profileList: common([]) + [alias, "hermes", "profile", "list"]
        case .profileLocks: common([]) + [alias, ProfileLock.command]
        }
    }

    private static func common(_ mode: [String]) -> [String] {
        var args = mode + ["-T"]
        for option in [
            "BatchMode=yes", "ExitOnForwardFailure=yes", "ForwardAgent=no",
            "ControlMaster=no", "ControlPath=none",
            "ForkAfterAuthentication=no", "LogLevel=ERROR",
            "ConnectTimeout=5", "ServerAliveInterval=5", "ServerAliveCountMax=2",
        ] {
            args += ["-o", option]
        }
        return args
    }

    static func isAlias(_ value: String) -> Bool {
        (1...253).contains(value.count) && value.first != "-"
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    private static func isHostname(_ value: String) -> Bool {
        (1...253).contains(value.count) && value.first != "-"
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._:-".contains($0)) }
    }
}

/// L'environnement des processus ssh est construit à la main : l'app peut porter des variables de test
/// `SSH_AUTH_SOCK` vient de la session ; `IdentityAgent` de la config ssh a priorité, ssh l'applique lui-même
enum SSHChildEnvironment {
    static func make(_ session: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        for key in ["HOME", "USER", "LOGNAME", "SSH_AUTH_SOCK"] {
            if let value = session[key], !value.isEmpty { environment[key] = value }
        }
        return environment
    }
}

// MARK: - Processus enfants

/// Un processus lancé par `posix_spawn`, avec la sortie d'erreur gardée en mémoire (8 Kio au plus) et la sortie standard gardée en entier
final class Child: Sendable {
    let pid: pid_t
    /// le groupe de processus auquel il appartient ; un signal envoyé au groupe atteint toute sa descendance
    let group: pid_t
    let ownsGroup: Bool
    private let exitTask: Task<Int32, Never>
    private let readers: [Task<Void, Never>]
    private let stdoutBuffer = OSAllocatedUnfairLock(initialState: Data())
    private let stderrBuffer = OSAllocatedUnfairLock(initialState: Data())
    private let exited = OSAllocatedUnfairLock(initialState: false)
    private let heldStdin: OSAllocatedUnfairLock<Int32?>

    fileprivate init(pid: pid_t, group: pid_t, ownsGroup: Bool, stdoutFD: Int32?, stderrFD: Int32, heldStdin: Int32?, stderrLimit: Int = Spawn.maxStderr) {
        self.pid = pid
        self.group = group
        self.ownsGroup = ownsGroup
        self.heldStdin = OSAllocatedUnfairLock(initialState: heldStdin)
        let exited = self.exited
        exitTask = Task {
            await Spawn.blocking {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1, errno == EINTR {}
                exited.withLock { $0 = true }
                // WIFEXITED / WEXITSTATUS / WTERMSIG : les macros ne sont pas importées
                return status & 0x7f == 0 ? (status >> 8) & 0xff : -(status & 0x7f)
            }
        }
        var readers = [Task<Void, Never>]()
        let errBuffer = stderrBuffer
        readers.append(Task { await Spawn.blocking { Spawn.drain(stderrFD, into: errBuffer, limit: stderrLimit) } })
        if let stdoutFD {
            let outBuffer = stdoutBuffer
            readers.append(Task { await Spawn.blocking { Spawn.drain(stdoutFD, into: outBuffer, limit: .max) } })
        }
        self.readers = readers
    }

    deinit { closeStdin() }

    var hasExited: Bool { exited.withLock { $0 } }

    /// Ferme le tube d'entrée tenu ouvert ; le noyau fait la même chose quand l'app meurt
    func closeStdin() {
        if let fd = heldStdin.withLock({ let held = $0; $0 = nil; return held }) { Darwin.close(fd) }
    }

    /// Code de sortie, ou l'opposé du numéro du signal qui l'a tué
    func waitForExit() async -> Int32 { await exitTask.value }

    /// Attend la fin du processus puis la fin de la lecture de ses sorties
    func finished() async -> Spawn.Output {
        let status = await exitTask.value
        for reader in readers { await reader.value }
        return Spawn.Output(
            status: status,
            stdout: String(decoding: stdoutBuffer.withLock { $0 }, as: UTF8.self),
            stderr: String(decoding: stderrBuffer.withLock { $0 }, as: UTF8.self)
        )
    }
}

enum SpawnError: Error, Equatable {
    case failed(errno: Int32)
    case timedOut
}

enum Spawn {
    struct Output: Sendable, Equatable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    fileprivate static let maxStderr = 8192

    /// Lance `path` dans un groupe de processus neuf, ou dans celui de `leader`
    /// Le processus n'hérite ni de l'environnement de l'app (il reçoit `environment` seulement) ni de ses descripteurs
    /// `holdingStdinOpen` : l'entrée standard du processus est un tube dont l'app garde l'écriture ouverte (voir `startWatchdog`)
    static func start(_ path: String, _ arguments: [String], environment: [String: String], joining leader: pid_t? = nil, stdin: Data? = nil, captureStdout: Bool = false, holdingStdinOpen: Bool = false, stderrLimit: Int = maxStderr) throws -> Child {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        var inPipe: [Int32] = [-1, -1], outPipe: [Int32] = [-1, -1], errPipe: [Int32] = [-1, -1]
        func closeAll() { for fd in inPipe + outPipe + errPipe where fd >= 0 { close(fd) } }
        let needsStdin = stdin != nil || holdingStdinOpen
        guard pipe(&errPipe) == 0, !needsStdin || pipe(&inPipe) == 0, !captureStdout || pipe(&outPipe) == 0 else {
            let code = errno
            closeAll()
            throw SpawnError.failed(errno: code)
        }

        if needsStdin { posix_spawn_file_actions_adddup2(&fileActions, inPipe[0], 0) } else { posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0) }
        if captureStdout { posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], 1) } else { posix_spawn_file_actions_addopen(&fileActions, 1, "/dev/null", O_WRONLY, 0) }
        posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], 2)

        // groupe à part, descripteurs fermés par défaut, signaux remis à zéro (l'app ignore SIGTERM pour le traiter elle-même)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, leader ?? 0)
        var allSignals = sigset_t(), noSignals = sigset_t()
        sigfillset(&allSignals)
        sigemptyset(&noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        var argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv + envp { free(pointer) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, path, &fileActions, &attributes, &argv, &envp)
        guard status == 0 else {
            closeAll()
            throw SpawnError.failed(errno: status)
        }
        close(errPipe[1])
        if captureStdout { close(outPipe[1]) }
        if needsStdin {
            close(inPipe[0])
            // une écriture sur un tube fermé ne doit pas tuer l'app
            _ = fcntl(inPipe[1], F_SETNOSIGPIPE, 1)
        }
        if let stdin {
            stdin.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = write(inPipe[1], buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0, errno == EINTR { continue }
                    if written <= 0 { break }
                    offset += written
                }
            }
            if !holdingStdinOpen { close(inPipe[1]) }
        }
        let held = holdingStdinOpen ? inPipe[1] : nil
        return Child(pid: pid, group: leader ?? pid, ownsGroup: leader == nil, stdoutFD: captureStdout ? outPipe[0] : nil, stderrFD: errPipe[0], heldStdin: held, stderrLimit: stderrLimit)
    }

    /// Le chef du groupe d'un tunnel : un sh qui lit son entrée standard, puis supprime le dossier privé et tue le groupe entier quand elle se ferme
    /// L'app tient l'autre bout du tube ; si elle meurt, même par SIGKILL, le noyau le ferme et aucun ssh ne survit
    static func startWatchdog(cleaning directory: URL? = nil) throws -> Child {
        let script = #"while read -r _; do :; done; [ -n "$1" ] && rm -f "$1/a" "$1/key.pub" "$1/known_hosts" && rmdir "$1"; kill -KILL 0"#
        return try start("/bin/sh", ["-c", script, "watchdog", directory?.path ?? ""], environment: ["PATH": "/usr/bin:/bin"], holdingStdinOpen: true)
    }

    /// Lance, attend la fin et rend les sorties ; au bout de `timeout` le processus est tué et l'appel échoue
    /// `killingGroup` : au délai, tue le groupe de `leader` entier, pas seulement le processus lancé
    static func run(_ path: String, _ arguments: [String], environment: [String: String], joining leader: pid_t? = nil, killingGroup: Bool = false, stdin: Data? = nil, timeout: Duration, stderrLimit: Int = maxStderr) async throws -> Output {
        let child = try start(path, arguments, environment: environment, joining: leader, stdin: stdin, captureStdout: true, stderrLimit: stderrLimit)
        let fired = OSAllocatedUnfairLock(initialState: false)
        let timer = Task {
            try await Task.sleep(for: timeout)
            fired.withLock { $0 = true }
            // le groupe entier si le processus en est le chef ou si l'appelant le demande, sinon lui seul
            if child.ownsGroup || killingGroup { killpg(child.group, SIGKILL) } else { kill(child.pid, SIGKILL) }
        }
        let output = await child.finished()
        timer.cancel()
        if fired.withLock({ $0 }) { throw SpawnError.timedOut }
        return output
    }

    /// Comme `run`, sous un gardien : le groupe est inscrit au registre d'arrêt, et le gardien le tue si l'app disparaît, même par SIGKILL
    /// Le groupe entier est tué au délai et à la fin de l'appel : la commande qu'un `Match exec` a lancée ne survit pas à `ssh -G`
    static func runGuarded(_ path: String, _ arguments: [String], environment: [String: String], timeout: Duration, stderrLimit: Int = maxStderr) async throws -> Output {
        let watchdog = try startWatchdog()
        ProcessGroups.register(watchdog.group)
        defer {
            ProcessGroups.unregister(watchdog.group)
            watchdog.closeStdin()
        }
        return try await run(path, arguments, environment: environment, joining: watchdog.pid, killingGroup: true, timeout: timeout, stderrLimit: stderrLimit)
    }

    /// Un appel bloquant (waitpid, read) hors du pool coopératif de Swift
    static func blocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: work()) }
        }
    }

    /// Lit `fd` jusqu'à sa fermeture et garde les `limit` premiers octets
    /// La sortie standard n'a pas de plafond : un plafond couperait en silence une table de profils et inventerait un profil
    /// Elle est bornée par le délai de `run` ; la sortie d'erreur ne sert qu'à un message, donc 8 Kio suffisent
    fileprivate static func drain(_ fd: Int32, into buffer: OSAllocatedUnfairLock<Data>, limit: Int) {
        defer { close(fd) }
        var chunk = [UInt8](repeating: 0, count: 2048)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { return }
            // la fin de la sortie est lue jusqu'au bout pour ne pas bloquer le processus, mais seul le début est gardé
            let received = Array(chunk[0..<count])
            buffer.withLock { if $0.count < limit { $0.append(contentsOf: received.prefix(limit - $0.count)) } }
        }
    }
}

/// Arrêt des groupes de processus : par signal sur le groupe, jamais sur le seul chef
enum ProcessGroups {
    private struct Entry {
        let group: pid_t
        let directory: URL?
    }

    private static let registry = OSAllocatedUnfairLock(initialState: [Entry]())
    // les sources de signaux vivent aussi longtemps que l'app
    nonisolated(unsafe) private static var signalSources = [any DispatchSourceSignal]()

    /// Inscrit un groupe à tuer quand l'app se ferme ; `directory` est supprimé en même temps
    static func register(_ group: pid_t, removing directory: URL? = nil) {
        registry.withLock { $0.append(Entry(group: group, directory: directory)) }
    }

    static func unregister(_ group: pid_t) {
        registry.withLock { $0.removeAll { $0.group == group } }
    }

    /// Tue sans attendre tous les groupes inscrits ; l'app se ferme, rien ne demande un arrêt propre
    static func killAll() {
        for entry in registry.withLock({ $0 }) {
            killpg(entry.group, SIGKILL)
            if let directory = entry.directory { try? FileManager.default.removeItem(at: directory) }
        }
    }

    /// SIGTERM, puis SIGKILL au bout de `grace` si un membre du groupe vit encore
    static func terminate(_ group: pid_t, grace: Duration) async {
        killpg(group, SIGTERM)
        let deadline = ContinuousClock.now + grace
        while killpg(group, 0) == 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        if killpg(group, 0) == 0 { killpg(group, SIGKILL) }
        unregister(group)
    }

    /// À appeler une fois, par l'app seulement : un test ne doit pas attraper les signaux de son hôte
    /// Fermeture normale, SIGTERM, SIGINT et SIGHUP tuent les groupes ; seul SIGKILL sur l'app laisse un ssh orphelin
    @MainActor static func installTerminationHooks() {
        guard signalSources.isEmpty else { return }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in killAll() }
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler(handler: terminationHandler(for: number))
            source.resume()
            signalSources.append(source)
        }
    }

    // hors de l'acteur principal : le gestionnaire tourne sur une file globale, et une fermeture isolée au principal y planterait
    private static func terminationHandler(for number: Int32) -> DispatchWorkItem {
        DispatchWorkItem {
            killAll()
            exit(128 + number)
        }
    }
}

// MARK: - Session et superviseur

struct SSHExit: Equatable, Sendable {
    let status: Int32
    let stderr: String
}

/// Nom de profil Hermes admis dans la commande figée, et lecture de `API_SERVER_KEY` sans jamais journaliser la valeur
enum HermesAPIKey {
    /// Commande CLI figée : `hermes -p <profil> config get API_SERVER_KEY --raw`
    static func remoteCommand(profile: String) -> [String] {
        ["hermes", "-p", profile, "config", "get", "API_SERVER_KEY", "--raw"]
    }

    static func validate(_ profile: String) throws -> String {
        guard (1...64).contains(profile.count), profile.first != "-",
              profile.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
            throw HermesProfileName.invalid
        }
        return profile
    }

    /// Une seule ligne, sans le reste de la sortie : la commande CLI ne doit rendre que la variable
    static func parse(_ stdout: String) -> String? {
        let line = stdout.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return line.isEmpty ? nil : line
    }

    static func missingMessage(profile: String) -> String {
        String(localized: "Clé API introuvable sur l'hôte pour le profil \(profile).")
    }

    /// Une clé détenue que Hermes refuse n'est pas une clé introuvable
    static func unauthorizedMessage(profile: String, holdsKey: Bool) -> String {
        holdsKey ? String(localized: "La clé API est refusée pour le profil \(profile).") : missingMessage(profile: profile)
    }
}

enum HermesProfileName: Error, Equatable {
    case invalid
}

enum APIKeyRecovery {
    /// Lit uniquement `API_SERVER_KEY` du profil demandé ; pas de repli sur `default`
    nonisolated(nonsending) static func refresh(profile: String, into secrets: inout some SecretStore, fetch: (String) async throws -> String?) async throws -> String? {
        let profile = try HermesAPIKey.validate(profile)
        guard let value = try await fetch(profile), let key = HermesAPIKey.parse(value) else { return nil }
        try secrets.setAPIKey(key, profile: profile)
        return key
    }
}

/// Une lecture SSH par profil et par refus ; un nouvel essai explicite de l'utilisateur la rouvre
@MainActor
final class APIKeyFetches {
    private var attempted: Set<String> = []

    /// nil si la garde est fermée pour ce profil, si la lecture échoue ou si la clé est introuvable ; la valeur n'est pas journalisée
    func fetch(profile: String, into secrets: inout some SecretStore, read: (String) async throws -> String?) async -> String? {
        guard attempted.insert(profile).inserted else { return nil }
        return try? await APIKeyRecovery.refresh(profile: profile, into: &secrets, fetch: read)
    }

    /// Le profil a répondu : le prochain refus peut relire
    func settle(_ profile: String) { attempted.remove(profile) }

    func reset() { attempted.removeAll() }
}

/// Un ssh vivant : son port local est déjà ouvert quand la session existe
struct SSHSession: Sendable {
    let localPort: Int
    /// rend la main quand ssh se termine
    let exited: @Sendable () async -> SSHExit
}

protocol SSHBackend: Sendable {
    /// Lance ssh et rend la main quand le port local accepte les connexions ; échoue avec un `SSHFailure`
    func open(_ config: SSHTunnelConfig) async throws -> SSHSession
    /// Tue ssh et tout ce qui lui est lié, y compris ce qu'une ouverture en cours est en train de préparer
    /// Peut être appelé plusieurs fois : le superviseur le rappelle quand une ouverture finit après avoir été abandonnée
    func close() async
}

/// Garde un tunnel ouvert : le rouvre quand il tombe, s'arrête sur une erreur qu'un nouvel essai ne règle pas
@MainActor @Observable
final class SSHTunnel {
    enum State: Equatable, Sendable {
        case idle
        case opening
        case open(localPort: Int)
        case reopening(attempt: Int)
        case failed(SSHFailure)
    }

    private(set) var state = State.idle
    private let delays: [Duration]
    private var generation = 0
    private var supervisor: Task<Void, Never>?
    private var backend: (any SSHBackend)?

    /// `delays` sépare deux essais de suite, le dernier valant pour les suivants
    init(delays: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10)]) {
        self.delays = delays
    }

    func start(_ config: SSHTunnelConfig, backend: any SSHBackend) {
        let previous = detach()
        if let previous { Task { await previous.close() } }
        self.backend = backend
        state = .opening
        let id = generation
        supervisor = Task { await run(config, backend, id) }
    }

    /// Montre une erreur trouvée avant tout lancement de ssh (alias inconnu, hôte refusé)
    func refuse(_ failure: SSHFailure) {
        if let previous = detach() { Task { await previous.close() } }
        state = .failed(failure)
    }

    func stop() async {
        let previous = detach()
        state = .idle
        await previous?.close()
    }

    private func detach() -> (any SSHBackend)? {
        generation += 1
        supervisor?.cancel()
        supervisor = nil
        defer { backend = nil }
        return backend
    }

    private func run(_ config: SSHTunnelConfig, _ backend: any SSHBackend, _ id: Int) async {
        var failures = 0
        var attempt = 0
        while generation == id {
            state = attempt == 0 ? .opening : .reopening(attempt: attempt)
            let failure: SSHFailure
            do {
                let session = try await backend.open(config)
                // ouverture abandonnée (stop ou remplacement) pendant qu'elle durait : la ressource qu'elle vient de créer n'a plus de propriétaire
                guard generation == id else { await backend.close(); return }
                state = .open(localPort: session.localPort)
                failures = 0
                let exit = await session.exited()
                guard generation == id else { return }
                failure = SSHFailure.classify(stderr: exit.stderr)
            } catch {
                guard generation == id else { return }
                failure = error as? SSHFailure ?? .unreachable("\(error)")
            }
            guard failure.retries else {
                state = .failed(failure)
                return
            }
            let delay = delays[min(failures, delays.count - 1)]
            failures += 1
            attempt += 1
            try? await Task.sleep(for: delay)
        }
    }
}

// MARK: - ssh système

/// Ouvre le tunnel avec `/usr/bin/ssh` (chemin absolu : le `ssh` du PATH d'un shell peut être un alias)
/// La config et l'agent de l'utilisateur s'appliquent : pas de `-F /dev/null`, pas de `-i`, pas d'agent privé
/// Les ssh sont dans un seul groupe de processus, tué d'un coup à la fermeture
actor SystemSSHBackend: SSHBackend {
    private let environment: [String: String]
    private var watchdog: Child?
    /// le gardien en préparation, que `close()` arrête sans attendre la fin de l'ouverture
    private var preparing: Child?
    private var closed = false

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    func open(_ config: SSHTunnelConfig) async throws -> SSHSession {
        try ensureLive()
        let watchdog = try preparedWatchdog()
        let localPort = try Self.freeLocalPort()
        let ssh: Child
        do {
            ssh = try Spawn.start(
                "/usr/bin/ssh",
                config.arguments(localPort: localPort),
                environment: SSHChildEnvironment.make(environment),
                joining: watchdog.pid
            )
        } catch {
            throw SSHFailure.unreachable("ssh ne démarre pas")
        }
        // ssh -N ne dit rien quand il est prêt : le port local s'ouvre après l'authentification
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            try ensureLive()
            if ssh.hasExited { throw SSHFailure.classify(stderr: await ssh.finished().stderr) }
            if Self.accepts(port: localPort) {
                return SSHSession(localPort: localPort) {
                    let output = await ssh.finished()
                    return SSHExit(status: output.status, stderr: output.stderr)
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        kill(ssh.pid, SIGKILL)
        _ = await ssh.waitForExit()
        throw SSHFailure.unreachable("délai dépassé")
    }

    /// Lit `hermes profile list` sur l'hôte par un second ssh (décision S6) et rend sa sortie
    func readProfileList(_ config: SSHTunnelConfig) async throws -> String {
        try ensureLive()
        guard let watchdog else { throw SSHFailure.unreachable("tunnel fermé") }
        let output: Spawn.Output
        do {
            output = try await Spawn.run(
                "/usr/bin/ssh",
                config.profileListArguments(),
                environment: SSHChildEnvironment.make(environment),
                joining: watchdog.pid,
                timeout: .seconds(15)
            )
        } catch SpawnError.timedOut {
            throw SSHFailure.unreachable("délai dépassé")
        } catch {
            throw SSHFailure.unreachable("ssh ne démarre pas")
        }
        // 255 : ssh lui-même a échoué (identité refusée, hôte injoignable) ; tout autre code vient de la commande distante
        if output.status == 255 { throw SSHFailure.classify(stderr: output.stderr) }
        guard output.status == 0 else {
            throw RemoteCommandFailure(status: output.status, detail: output.stderr.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "")
        }
        return output.stdout
    }

    /// Lit `API_SERVER_KEY` du profil par le même ssh que le tunnel ; la valeur ne quitte pas cette fonction que vers l'appelant
    func readAPIKey(_ config: SSHTunnelConfig, profile: String) async throws -> String? {
        try ensureLive()
        guard let watchdog else { throw SSHFailure.unreachable("tunnel fermé") }
        let output: Spawn.Output
        do {
            output = try await Spawn.run(
                "/usr/bin/ssh",
                try config.apiKeyArguments(profile: profile),
                environment: SSHChildEnvironment.make(environment),
                joining: watchdog.pid,
                timeout: .seconds(15)
            )
        } catch SpawnError.timedOut {
            throw SSHFailure.unreachable("délai dépassé")
        } catch let error as HermesProfileName {
            throw error
        } catch {
            throw SSHFailure.unreachable("ssh ne démarre pas")
        }
        if output.status == 255 { throw SSHFailure.classify(stderr: output.stderr) }
        guard output.status == 0 else { return nil }
        return HermesAPIKey.parse(output.stdout)
    }

    func readProfileLocks(_ config: SSHTunnelConfig) async throws -> Data {
        try ensureLive()
        guard let watchdog else { throw SSHFailure.unreachable("tunnel fermé") }
        let output = try await Spawn.run(
            "/usr/bin/ssh", config.profileLocksArguments(),
            environment: SSHChildEnvironment.make(environment),
            joining: watchdog.pid, timeout: .seconds(3)
        )
        guard output.status == 0 else { throw SSHFailure.unreachable("détection Desktop indisponible") }
        return Data(output.stdout.utf8)
    }

    func close() async {
        closed = true
        if let preparing {
            self.preparing = nil
            await release(preparing, grace: .seconds(1))
        }
        guard let watchdog else { return }
        self.watchdog = nil
        await release(watchdog, grace: .seconds(2))
    }

    /// Un `close()` ou une annulation de la tâche survenus pendant une attente : l'ouverture s'arrête
    private func ensureLive() throws {
        if closed || Task.isCancelled { throw CancellationError() }
    }

    private func release(_ watchdog: Child, grace: Duration) async {
        await ProcessGroups.terminate(watchdog.group, grace: grace)
        watchdog.closeStdin()
    }

    private func preparedWatchdog() throws -> Child {
        if let watchdog { return watchdog }
        let watchdog: Child
        do {
            watchdog = try Spawn.startWatchdog()
        } catch {
            throw SSHFailure.unreachable("ssh ne démarre pas")
        }
        ProcessGroups.register(watchdog.group)
        preparing = watchdog
        if closed || Task.isCancelled {
            preparing = nil
            watchdog.closeStdin()
            killpg(watchdog.group, SIGKILL)
            throw CancellationError()
        }
        preparing = nil
        self.watchdog = watchdog
        return watchdog
    }

    private static func loopback(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
        return address
    }

    /// Un port libre de 127.0.0.1, rendu au système avant que ssh le prenne
    private static func freeLocalPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SSHFailure.unreachable("socket") }
        defer { Darwin.close(fd) }
        var address = loopback(port: 0)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw SSHFailure.unreachable("bind") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard named == 0 else { throw SSHFailure.unreachable("getsockname") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func accepts(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var address = loopback(port: port)
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }
}
