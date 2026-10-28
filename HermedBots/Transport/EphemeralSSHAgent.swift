import AppSettings
import Darwin
import Foundation

/// Chemin d'un exécutable choisi par l'utilisateur : absolu, fichier, exécutable
enum SSHLaunchPath {
    static func isExecutable(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("://") else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }
}

protocol SSHPrivateKeySource: Sendable {
    func load() async throws -> Data
}

struct DataPrivateKeySource: SSHPrivateKeySource {
    let data: Data

    func load() async throws -> Data {
        if data.isEmpty { throw SSHFailure.missingKey }
        return data
    }
}

/// Exécutable qui écrit la clé privée sur la sortie standard ; la valeur n'est ni journalisée ni écrite
/// Il tourne sous un gardien : l'arrêt de l'app, même par SIGKILL, le tue avec ses descendants
struct CommandPrivateKeySource: SSHPrivateKeySource {
    let path: String
    let environment: [String: String]

    func load() async throws -> Data {
        guard SSHLaunchPath.isExecutable(path) else { throw SSHFailure.missingKey }
        let output: Spawn.Output
        do {
            output = try await Spawn.runGuarded(
                path,
                [],
                environment: SSHChildEnvironment.forUserTool(environment),
                timeout: .seconds(8)
            )
        } catch {
            throw SSHFailure.missingKey
        }
        let data = Data(output.stdout.utf8)
        if output.status != 0 || data.isEmpty { throw SSHFailure.missingKey }
        return data
    }
}

struct SSHClientSettings: Equatable, Sendable {
    var authMode: SSHAuthMode = .sessionAgent
    var wrapperPath: String = ""
    var keyCommandPath: String = ""
    var sshBinary: String = "/usr/bin/ssh"
}

/// Agent `ssh-agent` privé : socket seulement sur disque, clé uniquement en mémoire via `ssh-add -`
struct EphemeralSSHAgent: Sendable {
    let directory: URL
    let socketPath: String
    let child: Child

    static let socketName = "a"
    static let lifetimeSeconds = 300

    static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hb-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    static func start(joining leader: pid_t, directory: URL) async throws -> EphemeralSSHAgent {
        let socketPath = directory.appendingPathComponent(socketName).path
        let child: Child
        do {
            child = try Spawn.start(
                "/usr/bin/ssh-agent",
                ["-D", "-a", socketPath],
                environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"],
                joining: leader
            )
        } catch {
            throw SSHFailure.missingAgent
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if child.hasExited { throw SSHFailure.missingAgent }
            if FileManager.default.fileExists(atPath: socketPath) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard FileManager.default.fileExists(atPath: socketPath), !child.hasExited else {
            kill(child.pid, SIGKILL)
            _ = await child.waitForExit()
            throw SSHFailure.missingAgent
        }
        return EphemeralSSHAgent(directory: directory, socketPath: socketPath, child: child)
    }

    func addKey(_ data: Data, joining leader: pid_t, lifetime: Int = EphemeralSSHAgent.lifetimeSeconds) async throws {
        if data.isEmpty { throw SSHFailure.missingKey }
        let output: Spawn.Output
        do {
            output = try await Spawn.run(
                "/usr/bin/ssh-add",
                ["-t", "\(lifetime)", "-"],
                environment: SSHChildEnvironment.make(["SSH_AUTH_SOCK": socketPath]),
                joining: leader,
                stdin: data,
                timeout: .seconds(5)
            )
        } catch {
            throw SSHFailure.missingKey
        }
        if output.status != 0 { throw SSHFailure.missingKey }
        try await verifyHasIdentity(joining: leader)
    }

    func verifyHasIdentity(joining leader: pid_t) async throws {
        let output: Spawn.Output
        do {
            output = try await Spawn.run(
                "/usr/bin/ssh-add",
                ["-l"],
                environment: SSHChildEnvironment.make(["SSH_AUTH_SOCK": socketPath]),
                joining: leader,
                timeout: .seconds(5)
            )
        } catch {
            throw SSHFailure.missingAgent
        }
        if output.status == 2 || output.stderr.contains("Error connecting to agent")
            || output.stderr.contains("Could not open a connection to your authentication agent") {
            throw SSHFailure.missingAgent
        }
        if output.status != 0 || output.stdout.contains("The agent has no identities") {
            throw SSHFailure.missingKey
        }
    }
}
