import AppSettings
import CryptoKit
import Darwin
import Foundation
import os
import XCTest

final class EphemeralSSHAgentTests: XCTestCase {
    private static func gone(_ pid: pid_t) async -> Bool {
        for _ in 0..<80 {
            if kill(pid, 0) == -1, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    private func installDouble(exitFatallyAfterAccept: Bool = false) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hb-ssh-double-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("ssh-double").path
        let script = """
        #!/bin/sh
        agent=""
        localport=""
        prev=""
        for arg in "$@"; do
          if [ "$prev" = "-o" ]; then
            case "$arg" in
              IdentityAgent=*)
                agent="${arg#IdentityAgent=}"
                agent="${agent#\\"}"
                agent="${agent%\\"}"
                ;;
            esac
          fi
          if [ "$prev" = "-L" ]; then
            localport=$(printf '%s' "$arg" | awk -F: '{print $2}')
          fi
          prev="$arg"
        done
        if [ -z "$agent" ]; then
          printf '%s\\n' 'user@example.invalid: Permission denied (publickey).' >&2
          exit 255
        fi
        if ! SSH_AUTH_SOCK="$agent" /usr/bin/ssh-add -l >/dev/null 2>&1; then
          status=$?
          if [ "$status" -eq 2 ]; then
            printf '%s\\n' 'Error connecting to agent: No such file or directory' >&2
          else
            printf '%s\\n' 'The agent has no identities.' >&2
          fi
          exit 255
        fi
        if [ -z "$localport" ]; then
          exit 0
        fi
        \(exitFatallyAfterAccept
            ? #"exec /usr/bin/python3 -c 'import socket,sys,time; p=int(sys.argv[1]); s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",p)); s.listen(1); s.settimeout(30); c,_=s.accept(); time.sleep(0.4); sys.stderr.write("user@example.invalid: Permission denied (publickey).\n"); sys.exit(255)' "$localport""#
            : #"exec /usr/bin/python3 -c 'import socket,sys,time; p=int(sys.argv[1]); s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",p)); s.listen(1); s.settimeout(30); c,_=s.accept(); time.sleep(2)' "$localport""#)
        """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return path
    }

    func testTheTemporaryAgentLoadsAKeyFromStdinAndIsDestroyedAfterwards() async throws {
        let watchdog = try Spawn.startWatchdog()
        addTeardownBlock {
            watchdog.closeStdin()
            killpg(watchdog.group, SIGKILL)
        }
        let directory = try EphemeralSSHAgent.makeDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let agent = try await EphemeralSSHAgent.start(joining: watchdog.pid, directory: directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names, [EphemeralSSHAgent.socketName])
        try await agent.addKey(OpenSSHFixture.ed25519(), joining: watchdog.pid)
        try await agent.verifyHasIdentity(joining: watchdog.pid)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [EphemeralSSHAgent.socketName])
        kill(agent.child.pid, SIGKILL)
        let agentGone = await Self.gone(agent.child.pid)
        XCTAssertTrue(agentGone)
        do {
            try await agent.verifyHasIdentity(joining: watchdog.pid)
            XCTFail("l'agent tué a encore une identité")
        } catch let failure as SSHFailure {
            XCTAssertEqual(failure, .missingAgent)
            XCTAssertFalse(failure.message.contains("publickey"))
        }
    }

    func testAMissingAgentIsNamedInsteadOfPublickey() {
        XCTAssertEqual(SSHFailure.classify(stderr: "Error connecting to agent: No such file or directory", status: 255), .missingAgent)
        XCTAssertEqual(SSHFailure.classify(stderr: "user@example.invalid: Permission denied (publickey).", status: 255), .wrongKey(""))
        XCTAssertEqual(SSHFailure.missingAgent.message, "L'agent SSH est absent. Démarre l'agent, puis réessaie.")
    }

    func testTheTunnelOpensWhenTheTemporaryAgentHoldsTheKey() async throws {
        let double = try installDouble()
        let key = try OpenSSHFixture.ed25519()
        let backend = SystemSSHBackend(
            environment: ["PATH": "/usr/bin:/bin", "HOME": "/tmp/example-home", "USER": "user", "LOGNAME": "user"],
            resolver: AgreeingSSHResolver(),
            client: SSHClientSettings(authMode: .ephemeralAgent, sshBinary: double),
            keySource: DataPrivateKeySource(data: key)
        )
        let config = try SSHTunnelConfig(
            alias: "lab.invalid",
            hostname: "example.invalid",
            user: "user",
            sshPort: 2200,
            refuseTestHost: true
        )
        let session = try await backend.open(config)
        XCTAssertTrue((1...65535).contains(session.localPort))
        await backend.close()
    }

    func testAnEmptyKeyCommandAttachesToTheResolvedIdentityAgentWithoutAPrivateAgent() async throws {
        let watchdog = try Spawn.startWatchdog()
        addTeardownBlock {
            watchdog.closeStdin()
            killpg(watchdog.group, SIGKILL)
        }
        let directory = try EphemeralSSHAgent.makeDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let agent = try await EphemeralSSHAgent.start(joining: watchdog.pid, directory: directory)
        try await agent.addKey(OpenSSHFixture.ed25519(), joining: watchdog.pid)
        let backend = SystemSSHBackend(
            environment: ["PATH": "/usr/bin:/bin", "HOME": "/tmp/example-home", "USER": "user", "LOGNAME": "user"],
            resolver: AgreeingSSHResolver(identityAgent: agent.socketPath),
            client: SSHClientSettings(authMode: .ephemeralAgent, sshBinary: try installDouble()),
            keySource: nil
        )
        addTeardownBlock { await backend.close() }
        let config = try SSHTunnelConfig(
            alias: "lab.invalid",
            hostname: "example.invalid",
            user: "user",
            sshPort: 2200,
            refuseTestHost: true
        )
        let session = try await backend.open(config)
        XCTAssertTrue((1...65535).contains(session.localPort))
        let pid = await backend.temporaryAgentPID()
        let socket = await backend.temporaryAgentSocketPath()
        XCTAssertNil(pid)
        XCTAssertNil(socket)
        let listed = try await Spawn.run(
            "/usr/bin/ssh-add",
            ["-l"],
            environment: SSHChildEnvironment.make(["SSH_AUTH_SOCK": agent.socketPath]),
            timeout: .seconds(5)
        )
        XCTAssertEqual(listed.status, 0)
        await backend.close()
    }

    func testAttachResolvesIdentityAgentFromSSHAuthSockInTheLaunchEnvironment() async throws {
        let watchdog = try Spawn.startWatchdog()
        addTeardownBlock {
            watchdog.closeStdin()
            killpg(watchdog.group, SIGKILL)
        }
        let directory = try EphemeralSSHAgent.makeDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let agent = try await EphemeralSSHAgent.start(joining: watchdog.pid, directory: directory)
        try await agent.addKey(OpenSSHFixture.ed25519(), joining: watchdog.pid)
        let backend = SystemSSHBackend(
            environment: [
                "PATH": "/usr/bin:/bin",
                "HOME": "/tmp/example-home",
                "USER": "user",
                "LOGNAME": "user",
                "SSH_AUTH_SOCK": agent.socketPath,
            ],
            resolver: AgreeingSSHResolver(identityAgent: "$SSH_AUTH_SOCK"),
            client: SSHClientSettings(authMode: .ephemeralAgent, sshBinary: try installDouble()),
            keySource: nil
        )
        addTeardownBlock { await backend.close() }
        let config = try SSHTunnelConfig(
            alias: "lab.invalid",
            hostname: "example.invalid",
            user: "user",
            sshPort: 2200,
            refuseTestHost: true
        )
        let session = try await backend.open(config)
        XCTAssertTrue((1...65535).contains(session.localPort))
        let pid = await backend.temporaryAgentPID()
        let socket = await backend.temporaryAgentSocketPath()
        XCTAssertNil(pid)
        XCTAssertNil(socket)
        let listed = try await Spawn.run(
            "/usr/bin/ssh-add",
            ["-l"],
            environment: SSHChildEnvironment.make(["SSH_AUTH_SOCK": agent.socketPath]),
            timeout: .seconds(5)
        )
        XCTAssertEqual(listed.status, 0)
        await backend.close()
    }

    @MainActor
    func testAFatalErrorAfterAnOpenTunnelDestroysTheTemporaryAgent() async throws {
        let backend = SystemSSHBackend(
            environment: ["PATH": "/usr/bin:/bin", "HOME": "/tmp/example-home", "USER": "user", "LOGNAME": "user"],
            resolver: AgreeingSSHResolver(),
            client: SSHClientSettings(authMode: .ephemeralAgent, sshBinary: try installDouble(exitFatallyAfterAccept: true)),
            keySource: DataPrivateKeySource(data: try OpenSSHFixture.ed25519())
        )
        let config = try SSHTunnelConfig(alias: "lab.invalid", hostname: "example.invalid", user: "user", sshPort: 2200, refuseTestHost: true)
        addTeardownBlock { await backend.close() }
        let tunnel = SSHTunnel(delays: [.milliseconds(10)])
        tunnel.start(config, backend: backend)
        let opened = await wait(until: { if case .open = tunnel.state { true } else { false } })
        XCTAssertTrue(opened, "\(tunnel.state)")
        let socket = await backend.temporaryAgentSocketPath()
        let pid = await backend.temporaryAgentPID()
        XCTAssertNotNil(socket)
        XCTAssertNotNil(pid)
        let listed = try await Spawn.run(
            "/usr/bin/ssh-add",
            ["-l"],
            environment: SSHChildEnvironment.make(["SSH_AUTH_SOCK": socket!]),
            timeout: .seconds(5)
        )
        XCTAssertEqual(listed.status, 0)
        let failed = await wait(until: { if case .failed = tunnel.state { true } else { false } })
        XCTAssertTrue(failed, "\(tunnel.state)")
        guard case .failed(let failure) = tunnel.state else { return }
        XCTAssertFalse(failure.retries)
        XCTAssertEqual(failure, .wrongKey(""))
        let agentGone = await Self.gone(pid!)
        XCTAssertTrue(agentGone)
        let after = try await Spawn.run(
            "/usr/bin/ssh-add",
            ["-l"],
            environment: SSHChildEnvironment.make(["SSH_AUTH_SOCK": socket!]),
            timeout: .seconds(5)
        )
        XCTAssertEqual(after.status, 2)
        XCTAssertEqual(SSHFailure.classify(stderr: after.stderr), .missingAgent)
        XCTAssertFalse(SSHFailure.missingAgent.message.contains("publickey"))
    }

    @MainActor private func wait(until condition: @MainActor () -> Bool, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func expiringBackend(lifetime: Int) throws -> (SystemSSHBackend, CountingKeySource, SSHTunnelConfig) {
        let keys = CountingKeySource(data: try OpenSSHFixture.ed25519())
        let backend = SystemSSHBackend(
            environment: ["PATH": "/usr/bin:/bin", "HOME": "/tmp/example-home", "USER": "user", "LOGNAME": "user"],
            resolver: AgreeingSSHResolver(),
            client: SSHClientSettings(authMode: .ephemeralAgent, sshBinary: try installDouble()),
            keySource: keys,
            identityLifetime: lifetime
        )
        let config = try SSHTunnelConfig(alias: "lab.invalid", hostname: "example.invalid", user: "user", sshPort: 2200, refuseTestHost: true)
        addTeardownBlock { await backend.close() }
        return (backend, keys, config)
    }

    func testAnExpiredTemporaryIdentityIsReloadedBeforeAnAuxiliaryRead() async throws {
        let (backend, keys, config) = try expiringBackend(lifetime: 4)
        _ = try await backend.open(config)
        _ = try await backend.readProfileList(config)
        XCTAssertEqual(keys.count, 1, "la clé est rechargée alors qu'il lui reste plus de la marge")
        try await Task.sleep(for: .seconds(5))
        // `ssh-add -t 4` a retiré l'identité : sans rechargement, le double répond « The agent has no identities »
        _ = try await backend.readProfileList(config)
        XCTAssertEqual(keys.count, 2)
        _ = try await backend.readProfileLocks(config)
        XCTAssertEqual(keys.count, 2, "la clé est rechargée deux fois de suite")
        await backend.close()
    }

    func testAnExpiredTemporaryIdentityIsReloadedBeforeTheTunnelReopens() async throws {
        let (backend, keys, config) = try expiringBackend(lifetime: 2)
        _ = try await backend.open(config)
        try await Task.sleep(for: .seconds(3))
        let session = try await backend.open(config)
        XCTAssertTrue((1...65535).contains(session.localPort))
        XCTAssertEqual(keys.count, 2)
        await backend.close()
    }

    /// Un `Match exec` lit `SSH_AUTH_SOCK`, que l'agent temporaire remplace au lancement : `armed` fait entrer cette branche
    private func socketSensitiveBackend(body: String) throws -> (SystemSSHBackend, SSHTunnelConfig, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hb-match-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let armed = directory.appendingPathComponent("armed")
        let config = directory.appendingPathComponent("config")
        try """
        Match originalhost lab.invalid exec "test -e \(armed.path) && case $SSH_AUTH_SOCK in */a) true;; *) false;; esac"
        \(body)
        Host lab.invalid
          Hostname example.invalid
          User user
          Port 2200
        """.write(to: config, atomically: true, encoding: .utf8)
        let environment = ["PATH": "/usr/bin:/bin", "HOME": "/tmp/example-home", "USER": "user", "LOGNAME": "user"]
        let backend = SystemSSHBackend(
            environment: environment,
            resolver: SystemSSHConfigResolver(environment: environment, configFile: config.path),
            client: SSHClientSettings(authMode: .ephemeralAgent, sshBinary: try installDouble()),
            keySource: DataPrivateKeySource(data: try OpenSSHFixture.ed25519())
        )
        let tunnel = try SSHTunnelConfig(alias: "lab.invalid", hostname: "example.invalid", user: "user", sshPort: 2200, refuseTestHost: true)
        addTeardownBlock { await backend.close() }
        return (backend, tunnel, armed)
    }

    func testAMatchExecThatReadsTheAgentSocketCannotAddARelayToTheTunnelOpen() async throws {
        let (backend, config, armed) = try socketSensitiveBackend(body: "  Hostname alternate.invalid\n  ProxyJump relay.invalid")
        FileManager.default.createFile(atPath: armed.path, contents: nil)
        do {
            _ = try await backend.open(config)
            XCTFail("open() a lancé ssh avec un relais que la résolution de la session ne voyait pas")
        } catch let failure as SSHFailure {
            XCTAssertEqual(failure, .relayRefused)
        }
        // l'agent est détruit après l'échec : une lecture ne doit pas retomber sur l'agent de la session
        do {
            _ = try await backend.readProfileList(config)
            XCTFail("readProfileList a lancé ssh sans agent temporaire")
        } catch let failure as SSHFailure {
            XCTAssertEqual(failure, .missingAgent)
        }
    }

    func testAMatchExecThatReadsTheAgentSocketCannotAddARelayToAnAuxiliaryRead() async throws {
        let (backend, config, armed) = try socketSensitiveBackend(body: "  Hostname alternate.invalid\n  ProxyJump relay.invalid")
        _ = try await backend.open(config)
        FileManager.default.createFile(atPath: armed.path, contents: nil)
        func refused(_ read: () async throws -> Void, _ name: String) async {
            do {
                try await read()
                XCTFail("\(name) a lancé ssh avec un relais")
            } catch let failure as SSHFailure {
                XCTAssertEqual(failure, .relayRefused, name)
            } catch {
                XCTFail("\(name) : \(error)")
            }
        }
        await refused({ _ = try await backend.readProfileList(config) }, "readProfileList")
        await refused({ _ = try await backend.readProfileLocks(config) }, "readProfileLocks")
        await refused({ _ = try await backend.readAPIKey(config, profile: "hv-bot-a") }, "readAPIKey")
        try FileManager.default.removeItem(at: armed)
        _ = try await backend.readProfileList(config)
    }

    func testAMatchExecThatReadsTheAgentSocketCannotChangeTheDestination() async throws {
        let (backend, config, armed) = try socketSensitiveBackend(body: "  Hostname alternate.invalid")
        FileManager.default.createFile(atPath: armed.path, contents: nil)
        do {
            _ = try await backend.open(config)
            XCTFail("open() vise un hôte que la résolution de la session ne voyait pas")
        } catch let failure as SSHFailure {
            XCTAssertEqual(failure, .routeMismatch)
        }
    }

    func testAMissingWrapperIsNamedBeforeAnySpawn() async throws {
        let backend = SystemSSHBackend(
            environment: ["PATH": "/usr/bin:/bin"],
            client: SSHClientSettings(authMode: .wrapper, wrapperPath: "/tmp/example-wrapper.invalid")
        )
        let config = try SSHTunnelConfig(alias: "lab.invalid", hostname: "example.invalid", user: "user", sshPort: 2200, refuseTestHost: true)
        do {
            _ = try await backend.open(config)
            XCTFail("open() a réussi sans exécutable")
        } catch let failure as SSHFailure {
            XCTAssertEqual(failure, .missingWrapper)
            XCTAssertFalse(failure.message.contains("publickey"))
        }
        await backend.close()
    }

    func testAnEphemeralLaunchWithoutKeyCommandOrAgentIsNamedBeforeAnySpawn() async throws {
        // ni source de clé, ni commande de clé, ni IdentityAgent dans le dump : ssh ne doit pas partir, sinon il prendrait l'agent de la session
        let backend = SystemSSHBackend(
            environment: ["PATH": "/usr/bin:/bin"],
            resolver: AgreeingSSHResolver(),
            client: SSHClientSettings(authMode: .ephemeralAgent, sshBinary: "/tmp/example-ssh-never-spawned.invalid"),
            keySource: nil
        )
        let config = try SSHTunnelConfig(alias: "lab.invalid", hostname: "example.invalid", user: "user", sshPort: 2200, refuseTestHost: true)
        do {
            _ = try await backend.open(config)
            XCTFail("open() a réussi sans identité")
        } catch let failure as SSHFailure {
            XCTAssertEqual(failure, .noIdentity)
            XCTAssertFalse(failure.retries)
        }
        await backend.close()
    }

    func testAnEmptyKeySourceIsNamedInsteadOfPublickey() async throws {
        let backend = SystemSSHBackend(
            environment: ["PATH": "/usr/bin:/bin"],
            client: SSHClientSettings(authMode: .ephemeralAgent, sshBinary: "/usr/bin/true"),
            keySource: DataPrivateKeySource(data: Data())
        )
        let config = try SSHTunnelConfig(alias: "lab.invalid", hostname: "example.invalid", user: "user", sshPort: 2200, refuseTestHost: true)
        do {
            _ = try await backend.open(config)
            XCTFail("open() a réussi sans clé")
        } catch let failure as SSHFailure {
            XCTAssertEqual(failure, .missingKey)
            XCTAssertFalse(failure.message.contains("publickey"))
        }
        await backend.close()
    }
}

/// `ssh -G` d'un alias qui reste sur la route du tunnel de ces tests
private struct AgreeingSSHResolver: SSHConfigResolving {
    private let dump: SSHConfigDump

    init(identityAgent: String? = nil) {
        var stdout = "hostname example.invalid\nuser user\nport 2200\n"
        if let identityAgent {
            stdout += "identityagent \(identityAgent)\n"
        }
        dump = SSHConfigDump(stdout: stdout)
    }

    func dump(alias: String, invocation: SSHInvocation, agentSocket: String?) async throws -> SSHConfigDump { dump }

    func dumpAPIKey(alias: String, profile: String, agentSocket: String?) async throws -> SSHConfigDump { dump }
}

private final class CountingKeySource: SSHPrivateKeySource {
    private let data: Data
    private let loads = OSAllocatedUnfairLock(initialState: 0)

    init(data: Data) { self.data = data }

    var count: Int { loads.withLock { $0 } }

    func load() async throws -> Data {
        loads.withLock { $0 += 1 }
        return data
    }
}

private enum OpenSSHFixture {
    static func ed25519() throws -> Data {
        let key = Curve25519.Signing.PrivateKey()
        let seed = key.rawRepresentation
        let pub = key.publicKey.rawRepresentation
        return encode(seed: seed, publicKey: pub)
    }

    private static func encode(seed: Data, publicKey: Data) -> Data {
        func blob(_ data: Data) -> Data {
            var length = UInt32(data.count).bigEndian
            return Data(bytes: &length, count: 4) + data
        }
        let keyType = Data("ssh-ed25519".utf8)
        let publicBlob = blob(keyType) + blob(publicKey)
        let check = Data((0..<4).map { _ in UInt8.random(in: 0...255) })
        var inner = Data()
        inner += check
        inner += check
        inner += blob(keyType)
        inner += blob(publicKey)
        inner += blob(seed + publicKey)
        inner += blob(Data("fixture".utf8))
        let pad = (8 - (inner.count % 8)) % 8
        if pad > 0 { inner += Data((1...pad).map(UInt8.init)) }
        var body = Data("openssh-key-v1".utf8) + Data([0])
        body += blob(Data("none".utf8))
        body += blob(Data("none".utf8))
        body += blob(Data())
        var nkeys = UInt32(1).bigEndian
        body += Data(bytes: &nkeys, count: 4)
        body += blob(publicBlob)
        body += blob(inner)
        let wrapped = body.base64EncodedString().chunks(of: 70).joined(separator: "\n")
        return Data("-----BEGIN OPENSSH PRIVATE KEY-----\n\(wrapped)\n-----END OPENSSH PRIVATE KEY-----\n".utf8)
    }
}

private extension String {
    func chunks(of size: Int) -> [String] {
        var result: [String] = []
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(String(self[index..<next]))
            index = next
        }
        return result
    }
}
