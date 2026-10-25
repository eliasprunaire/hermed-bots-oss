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
    case invalidHost
    case invalidUser
    case invalidPort
    case keyMissing
    case keyUnreadable
    case wrongKey
    case hostKeyChanged
    case unreachable(String)

    var retries: Bool {
        if case .unreachable = self { true } else { false }
    }

    /// Lit la sortie d'erreur de ssh ; les textes sont ceux d'OpenSSH 10 (docs/spike/S12-tunnel.md)
    static func classify(stderr: String) -> SSHFailure {
        if stderr.contains("Permission denied") { return .wrongKey }
        if stderr.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || stderr.contains("Host key verification failed") { return .hostKeyChanged }
        let last = stderr.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return .unreachable(last)
    }
}

extension SSHFailure {
    var message: String {
        switch self {
        case .forbiddenHost: String(localized: "Cet hôte est refusé en mode test.")
        case .invalidHost: String(localized: "L'hôte n'est pas valide.")
        case .invalidUser: String(localized: "L'utilisateur n'est pas valide.")
        case .invalidPort: String(localized: "Le port n'est pas valide.")
        case .keyMissing: String(localized: "Aucune clé SSH dans le Trousseau. Ajoute-la, puis réessaie.")
        case .keyUnreadable: String(localized: "La clé SSH du Trousseau est illisible.")
        case .wrongKey: String(localized: "Le serveur refuse la clé SSH. Vérifie la clé du Trousseau, puis réessaie.")
        case .hostKeyChanged: String(localized: "La clé de l'hôte a changé. Le tunnel reste fermé.")
        case .unreachable(let reason): reason.isEmpty ? String(localized: "Hôte injoignable.") : String(localized: "Hôte injoignable : \(reason)")
        }
    }
}

/// La commande distante a répondu une erreur : son code de sortie et la dernière ligne de sa sortie d'erreur
struct RemoteCommandFailure: Error, Equatable, Sendable {
    let status: Int32
    let detail: String
}

/// Là où le tunnel se connecte et ce qu'il redirige : un port local vers `127.0.0.1:remotePort` de l'hôte
struct SSHTunnelConfig: Equatable, Sendable {
    let host: String
    let user: String
    let sshPort: Int
    let remotePort: Int

    /// `refusePersoHermes` est vrai en mode test : aucune connexion de test ne doit viser perso-hermes
    /// Le produit lui-même s'y connecte, donc le refus ne vaut pas hors mode test
    init(host: String, user: String, sshPort: Int = 22, remotePort: Int = 8642, refusePersoHermes: Bool) throws {
        if refusePersoHermes, host.lowercased().contains("perso-hermes") { throw SSHFailure.forbiddenHost }
        // pas de tiret en tête : l'hôte ne doit jamais se lire comme une option de ssh
        guard (1...253).contains(host.count), host.first != "-",
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._:-".contains($0)) }) else { throw SSHFailure.invalidHost }
        guard (1...32).contains(user.count), user.first != "-",
              user.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else { throw SSHFailure.invalidUser }
        guard (1...65535).contains(sshPort), (1...65535).contains(remotePort) else { throw SSHFailure.invalidPort }
        self.host = host
        self.user = user
        self.sshPort = sshPort
        self.remotePort = remotePort
    }

    /// Les arguments de `ssh` : chemins et ports seulement, jamais la clé, qui reste dans l'agent privé
    func arguments(localPort: Int, agentSocket: String, publicKeyPath: String, knownHostsPath: String) -> [String] {
        common(["-N"], agentSocket: agentSocket, publicKeyPath: publicKeyPath, knownHostsPath: knownHostsPath)
            + ["-L", "127.0.0.1:\(localPort):127.0.0.1:\(remotePort)", host]
    }

    /// Les arguments de la lecture de la liste des profils (décision S6)
    /// La commande est écrite ici et non passée en paramètre : aucun appelant ne peut en lancer une autre
    func profileListArguments(agentSocket: String, publicKeyPath: String, knownHostsPath: String) -> [String] {
        common([], agentSocket: agentSocket, publicKeyPath: publicKeyPath, knownHostsPath: knownHostsPath) + [host, "hermes", "profile", "list"]
    }

    private func common(_ mode: [String], agentSocket: String, publicKeyPath: String, knownHostsPath: String) -> [String] {
        // ssh découpe la valeur d'un -o sur les espaces : un chemin à espaces se met entre guillemets
        func quoted(_ path: String) -> String { path.contains(where: \.isWhitespace) ? "\"\(path)\"" : path }
        var args = ["-F", "/dev/null"] + mode + ["-T"]
        for option in [
            "BatchMode=yes", "ExitOnForwardFailure=yes", "ForwardAgent=no", "PasswordAuthentication=no",
            "KbdInteractiveAuthentication=no", "PreferredAuthentications=publickey", "IdentitiesOnly=yes", "AddKeysToAgent=no",
            "IdentityAgent=\(quoted(agentSocket))", "LogLevel=ERROR", "ConnectTimeout=5", "ServerAliveInterval=5", "ServerAliveCountMax=2",
            "StrictHostKeyChecking=accept-new", "UserKnownHostsFile=\(quoted(knownHostsPath))", "ControlMaster=no", "ControlPath=none",
        ] {
            args += ["-o", option]
        }
        args += ["-i", publicKeyPath, "-p", "\(sshPort)", "-l", user]
        return args
    }
}

/// L'environnement des processus ssh est construit à la main : celui de l'app peut contenir la clé de test
enum SSHChildEnvironment {
    static func make(agentSocket: String) -> [String: String] {
        ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "SSH_AUTH_SOCK": agentSocket]
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

    fileprivate init(pid: pid_t, group: pid_t, ownsGroup: Bool, stdoutFD: Int32?, stderrFD: Int32, heldStdin: Int32?) {
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
        readers.append(Task { await Spawn.blocking { Spawn.drain(stderrFD, into: errBuffer, limit: Spawn.maxStderr) } })
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
    static func start(_ path: String, _ arguments: [String], environment: [String: String], joining leader: pid_t? = nil, stdin: Data? = nil, captureStdout: Bool = false, holdingStdinOpen: Bool = false) throws -> Child {
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
        return Child(pid: pid, group: leader ?? pid, ownsGroup: leader == nil, stdoutFD: captureStdout ? outPipe[0] : nil, stderrFD: errPipe[0], heldStdin: held)
    }

    /// Le chef du groupe d'un tunnel : un sh qui lit son entrée standard, puis supprime le dossier privé et tue le groupe entier quand elle se ferme
    /// L'app tient l'autre bout du tube ; si elle meurt, même par SIGKILL, le noyau le ferme et aucun ssh ne survit
    static func startWatchdog(cleaning directory: URL? = nil) throws -> Child {
        let script = #"while read -r _; do :; done; [ -n "$1" ] && rm -f "$1/a" "$1/key.pub" "$1/known_hosts" && rmdir "$1"; kill -KILL 0"#
        return try start("/bin/sh", ["-c", script, "watchdog", directory?.path ?? ""], environment: ["PATH": "/usr/bin:/bin"], holdingStdinOpen: true)
    }

    /// Lance, attend la fin et rend les sorties ; au bout de `timeout` le processus est tué et l'appel échoue
    static func run(_ path: String, _ arguments: [String], environment: [String: String], joining leader: pid_t? = nil, stdin: Data? = nil, timeout: Duration) async throws -> Output {
        let child = try start(path, arguments, environment: environment, joining: leader, stdin: stdin, captureStdout: true)
        let fired = OSAllocatedUnfairLock(initialState: false)
        let timer = Task {
            try await Task.sleep(for: timeout)
            fired.withLock { $0 = true }
            // le groupe entier si le processus en est le chef, sinon lui seul
            if child.ownsGroup { killpg(child.group, SIGKILL) } else { kill(child.pid, SIGKILL) }
        }
        let output = await child.finished()
        timer.cancel()
        if fired.withLock({ $0 }) { throw SpawnError.timedOut }
        return output
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

    /// Montre une erreur trouvée avant tout lancement de ssh (hôte refusé, clé absente)
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
/// La clé privée va dans un `ssh-agent` privé par `ssh-add -` (entrée standard) : ni argument, ni fichier, ni variable d'environnement
/// L'agent et les ssh sont dans un seul groupe de processus, tué d'un coup à la fermeture
actor SystemSSHBackend: SSHBackend {
    private struct Agent {
        let watchdog: Child
        let child: Child
        let directory: URL
        let socket: String
        let publicKeyPath: String
    }

    private var key: String?
    private let knownHostsPath: String?
    private let workDirectory: URL
    private var agent: Agent?
    /// l'agent en préparation, que `close()` arrête sans attendre la fin de la préparation
    private var preparing: (watchdog: Child, directory: URL)?
    private var closed = false

    /// `knownHostsPath` nil : le fichier vit dans le dossier privé du tunnel et disparaît avec lui (mode test)
    /// `workDirectory` : là où le dossier privé du tunnel est créé
    init(key: String, knownHostsPath: String?, workDirectory: URL = FileManager.default.temporaryDirectory) {
        self.key = key
        self.knownHostsPath = knownHostsPath
        self.workDirectory = workDirectory
    }

    func open(_ config: SSHTunnelConfig) async throws -> SSHSession {
        try ensureLive()
        let agent = try await preparedAgent()
        let localPort = try Self.freeLocalPort()
        let knownHosts = knownHostsPath ?? agent.directory.appendingPathComponent("known_hosts").path
        let ssh: Child
        do {
            ssh = try Spawn.start(
                "/usr/bin/ssh",
                config.arguments(localPort: localPort, agentSocket: agent.socket, publicKeyPath: agent.publicKeyPath, knownHostsPath: knownHosts),
                environment: SSHChildEnvironment.make(agentSocket: agent.socket),
                joining: agent.watchdog.pid
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

    /// Lit `hermes profile list` sur l'hôte par un second ssh qui prend l'agent du tunnel ouvert (décision S6) et rend sa sortie
    /// À appeler tunnel ouvert : l'agent existe alors, aucune préparation ne se croise avec celle de `open`
    func readProfileList(_ config: SSHTunnelConfig) async throws -> String {
        try ensureLive()
        guard let agent else { throw SSHFailure.unreachable("tunnel fermé") }
        let knownHosts = knownHostsPath ?? agent.directory.appendingPathComponent("known_hosts").path
        let output: Spawn.Output
        do {
            output = try await Spawn.run(
                "/usr/bin/ssh",
                config.profileListArguments(agentSocket: agent.socket, publicKeyPath: agent.publicKeyPath, knownHostsPath: knownHosts),
                environment: SSHChildEnvironment.make(agentSocket: agent.socket),
                joining: agent.watchdog.pid,
                timeout: .seconds(15)
            )
        } catch SpawnError.timedOut {
            throw SSHFailure.unreachable("délai dépassé")
        } catch {
            throw SSHFailure.unreachable("ssh ne démarre pas")
        }
        // 255 : ssh lui-même a échoué (clé refusée, hôte injoignable) ; tout autre code vient de la commande distante
        if output.status == 255 { throw SSHFailure.classify(stderr: output.stderr) }
        guard output.status == 0 else {
            throw RemoteCommandFailure(status: output.status, detail: output.stderr.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "")
        }
        return output.stdout
    }

    func readProfileLocks(_ config: SSHTunnelConfig) async throws -> Data {
        try ensureLive()
        guard let agent else { throw SSHFailure.unreachable("tunnel fermé") }
        let knownHosts = knownHostsPath ?? agent.directory.appendingPathComponent("known_hosts").path
        let arguments = config.profileListArguments(agentSocket: agent.socket, publicKeyPath: agent.publicKeyPath, knownHostsPath: knownHosts)
        let output = try await Spawn.run(
            "/usr/bin/ssh", Array(arguments.dropLast(3)) + [ProfileLock.command],
            environment: SSHChildEnvironment.make(agentSocket: agent.socket),
            joining: agent.watchdog.pid, timeout: .seconds(3)
        )
        guard output.status == 0 else { throw SSHFailure.unreachable("détection Desktop indisponible") }
        return Data(output.stdout.utf8)
    }

    func close() async {
        closed = true
        key = nil
        if let preparing {
            self.preparing = nil
            await release(preparing.watchdog, preparing.directory, grace: .seconds(1))
        }
        guard let agent else { return }
        self.agent = nil
        await release(agent.watchdog, agent.directory, grace: .seconds(2))
    }

    /// Un `close()` ou une annulation de la tâche survenus pendant une attente : l'ouverture s'arrête
    private func ensureLive() throws {
        if closed || Task.isCancelled { throw CancellationError() }
    }

    /// Arrête le groupe du gardien (agent et ssh) et supprime le dossier privé ; sans effet si c'est déjà fait
    private func release(_ watchdog: Child, _ directory: URL, grace: Duration) async {
        await ProcessGroups.terminate(watchdog.group, grace: grace)
        watchdog.closeStdin()
        try? FileManager.default.removeItem(at: directory)
    }

    private func preparedAgent() async throws -> Agent {
        if let agent { return agent }
        guard let key else { throw SSHFailure.keyUnreadable }
        let directory = workDirectory.appendingPathComponent("hb-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let socket = directory.appendingPathComponent("a").path
        let environment = SSHChildEnvironment.make(agentSocket: socket)
        let watchdog: Child
        let child: Child
        do {
            watchdog = try Spawn.startWatchdog(cleaning: directory)
            child = try Spawn.start("/usr/bin/ssh-agent", ["-D", "-a", socket], environment: environment, joining: watchdog.pid)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw SSHFailure.unreachable("ssh-agent ne démarre pas")
        }
        ProcessGroups.register(watchdog.group, removing: directory)
        preparing = (watchdog, directory)

        func abandon(_ failure: any Error) async -> any Error {
            if preparing?.watchdog === watchdog { preparing = nil }
            await release(watchdog, directory, grace: .seconds(1))
            return failure
        }
        // chaque attente peut être interrompue par `close()` ou par l'annulation : l'agent en préparation est alors détruit, jamais gardé
        func live() async throws {
            if closed || Task.isCancelled { throw await abandon(CancellationError()) }
        }
        for _ in 0..<60 where !FileManager.default.fileExists(atPath: socket) {
            try? await Task.sleep(for: .milliseconds(50))
            try await live()
        }
        guard FileManager.default.fileExists(atPath: socket) else { throw await abandon(SSHFailure.unreachable("ssh-agent ne répond pas")) }

        // la clé arrive par l'entrée standard de ssh-add, avec un saut de ligne final que OpenSSH exige
        let material = Data((key.hasSuffix("\n") ? key : key + "\n").utf8)
        let added = try? await Spawn.run("/usr/bin/ssh-add", ["-"], environment: environment, joining: watchdog.pid, stdin: material, timeout: .seconds(8))
        try await live()
        guard added?.status == 0 else { throw await abandon(SSHFailure.keyUnreadable) }
        // la partie publique sert à dire à ssh quelle clé de l'agent signer ; elle n'a rien de secret
        let listed = try? await Spawn.run("/usr/bin/ssh-add", ["-L"], environment: environment, joining: watchdog.pid, timeout: .seconds(8))
        try await live()
        guard let listed, listed.status == 0, listed.stdout.hasPrefix("ssh-") || listed.stdout.hasPrefix("ecdsa-") else { throw await abandon(SSHFailure.keyUnreadable) }
        let publicKeyPath = directory.appendingPathComponent("key.pub").path
        guard FileManager.default.createFile(atPath: publicKeyPath, contents: Data(listed.stdout.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw await abandon(SSHFailure.keyUnreadable)
        }
        self.key = nil
        preparing = nil
        let ready = Agent(watchdog: watchdog, child: child, directory: directory, socket: socket, publicKeyPath: publicKeyPath)
        agent = ready
        return ready
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
