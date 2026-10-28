import AppSettings
import CryptoKit
import Darwin
import Foundation
import XCTest

final class EphemeralSSHAgentTests: XCTestCase {
    private func gone(_ pid: pid_t) async -> Bool {
        for _ in 0..<80 {
            if kill(pid, 0) == -1, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    private func installDouble() throws -> String {
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
              IdentityAgent=*) agent="${arg#IdentityAgent=}" ;;
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
        exec /usr/bin/python3 -c 'import socket,sys,time; p=int(sys.argv[1]); s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",p)); s.listen(1); s.settimeout(30); c,_=s.accept(); time.sleep(2)' "$localport"
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
        XCTAssertTrue(await gone(agent.child.pid))
        do {
            try await agent.verifyHasIdentity(joining: watchdog.pid)
            XCTFail("l'agent tué a encore une identité")
        } catch let failure as SSHFailure {
            XCTAssertEqual(failure, .missingAgent)
            XCTAssertFalse(failure.message.contains("publickey"))
        }
    }

    func testAMissingAgentIsNamedInsteadOfPublickey() {
        XCTAssertEqual(SSHFailure.classify(stderr: "Error connecting to agent: No such file or directory"), .missingAgent)
        XCTAssertEqual(SSHFailure.classify(stderr: "user@example.invalid: Permission denied (publickey)."), .wrongKey("user@example.invalid: Permission denied (publickey)."))
        XCTAssertEqual(SSHFailure.missingAgent.message, "L'agent SSH est absent. La connexion s'arrête.")
    }

    func testTheTunnelOpensWhenTheTemporaryAgentHoldsTheKey() async throws {
        let double = try installDouble()
        let backend = SystemSSHBackend(
            environment: ["PATH": "/usr/bin:/bin", "HOME": "/tmp/example-home", "USER": "user", "LOGNAME": "user"],
            client: SSHClientSettings(authMode: .ephemeralAgent, sshBinary: double),
            keySource: DataPrivateKeySource(data: OpenSSHFixture.ed25519())
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
