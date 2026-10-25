import Darwin
import XCTest

// compilé dans le paquet de tests lui-même, sans l'app comme hôte : aucun test ici n'ouvre de connexion réseau
final class SSHTunnelConfigTests: XCTestCase {
    private func config(alias: String = "lab.invalid", hostname: String = "gateway.invalid", refuse: Bool = true) throws -> SSHTunnelConfig {
        try SSHTunnelConfig(alias: alias, hostname: hostname, user: "operator", refusePersoHermes: refuse)
    }

    func testArgumentsOpenAForwardWithTheAliasAndTheUserConfig() throws {
        let args = try config().arguments(localPort: 51234)
        XCTAssertEqual(args.last, "lab.invalid")
        XCTAssertEqual(args.indices.filter { args[$0] == "-L" }.map { args[$0 + 1] }, ["127.0.0.1:51234:127.0.0.1:8642"])
        for required in ["-N", "-T", "BatchMode=yes", "ExitOnForwardFailure=yes", "ForwardAgent=no", "ControlMaster=no", "ControlPath=none", "ForkAfterAuthentication=no", "LogLevel=ERROR", "ConnectTimeout=5", "ServerAliveInterval=5", "ServerAliveCountMax=2"] {
            XCTAssertTrue(args.contains(required), required)
        }
        XCTAssertNil(args.firstIndex(of: "-F"))
        XCTAssertNil(args.firstIndex(of: "-i"))
        XCTAssertNil(args.firstIndex(of: "-l"))
        XCTAssertNil(args.firstIndex(of: "-p"))
        XCTAssertFalse(args.contains { $0.hasPrefix("IdentityAgent=") })
        XCTAssertFalse(args.contains { $0.hasPrefix("UserKnownHostsFile=") })
        XCTAssertFalse(args.contains("IdentitiesOnly=yes"))
    }

    func testTheProfileListReadRunsOnlyHermesProfileListWithNoForward() throws {
        let args = try config().profileListArguments()
        XCTAssertEqual(Array(args.suffix(4)), ["lab.invalid", "hermes", "profile", "list"])
        for absent in ["-N", "-L", "-R", "-D", "-F", "-i", "-l", "-p"] { XCTAssertFalse(args.contains(absent), absent) }
        for required in ["-T", "BatchMode=yes", "ForwardAgent=no", "ControlMaster=no", "ControlPath=none", "ConnectTimeout=5"] {
            XCTAssertTrue(args.contains(required), required)
        }
    }

    func testTheProfileLocksReadRunsOneFixedRemoteCommandWithNoForward() throws {
        let args = try config().profileLocksArguments()
        XCTAssertEqual(Array(args.suffix(2)), ["lab.invalid", ProfileLock.command])
        for absent in ["-N", "-L", "-R", "-D", "-F", "-i", "-l", "-p"] { XCTAssertFalse(args.contains(absent), absent) }
        XCTAssertEqual(Array(args.dropLast(2)), Array(try config().profileListArguments().dropLast(4)))
    }

    func testTheAPIKeyReadRunsOnlyTheFrozenHermesConfigGetWithTheSameAlias() throws {
        let args = try config().apiKeyArguments(profile: "cyber")
        XCTAssertEqual(Array(args.suffix(8)), ["lab.invalid", "hermes", "-p", "cyber", "config", "get", "API_SERVER_KEY", "--raw"])
        XCTAssertEqual(HermesAPIKey.remoteCommand(profile: "cyber"), ["hermes", "-p", "cyber", "config", "get", "API_SERVER_KEY", "--raw"])
        for absent in ["-N", "-L", "-R", "-D", "-F", "-i", "-l"] { XCTAssertFalse(args.contains(absent), absent) }
        XCTAssertEqual(args.indices.filter { args[$0] == "-p" }.map { args[$0 + 1] }, ["cyber"])
        for required in ["-T", "BatchMode=yes", "ForwardAgent=no", "ControlMaster=no", "ControlPath=none", "ConnectTimeout=5"] {
            XCTAssertTrue(args.contains(required), required)
        }
        XCTAssertNil(args.firstIndex(of: "-F"))
        XCTAssertNil(args.firstIndex(of: "-i"))
        XCTAssertNil(args.firstIndex(of: "-l"))
    }

    func testAnInvalidProfileNeverBuildsSSHArguments() {
        for profile in ["", "-p", "a b", "a;id", "ho$st", "a\nid", String(repeating: "p", count: 65)] {
            XCTAssertThrowsError(try config().apiKeyArguments(profile: profile), profile) {
                XCTAssertEqual($0 as? HermesProfileName, .invalid, profile)
            }
        }
    }

    func testUnauthorizedRecoveryFetchesOnlyTheNamedProfileAndNeverPutsTheKeyInMessages() async throws {
        let secret = "fetched-profile-key-VALUE"
        var store = InMemorySecretStore(apiKey: nil)
        var calls: [String] = []
        let key = try await APIKeyRecovery.refresh(profile: "cyber", into: &store) { name in
            calls.append(name)
            return name == "cyber" ? secret : "default-should-not-be-used"
        }
        XCTAssertEqual(key, secret)
        XCTAssertEqual(calls, ["cyber"])
        XCTAssertEqual(try store.apiKey(profile: "cyber"), secret)
        XCTAssertNil(try store.apiKey(profile: "default"))

        XCTAssertNil(HermesAPIKey.parse(" \n "))
        XCTAssertEqual(HermesAPIKey.parse("  \(secret)\nignored-line\n"), secret)

        let simulated = try await Spawn.run("/bin/sh", ["-c", "printf '%s\\n' '\(secret)'"], environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"], timeout: .seconds(5))
        XCTAssertEqual(simulated.status, 0)
        XCTAssertEqual(HermesAPIKey.parse(simulated.stdout), secret)
        XCTAssertFalse(HermesAPIKey.missingMessage(profile: "cyber").contains(secret))
    }

    @MainActor
    func testAnExplicitRetryReopensTheKeyReadAfterATemporaryFailure() async throws {
        let secret = "fetched-profile-key-VALUE"
        var store = InMemorySecretStore(apiKey: nil)
        let fetches = APIKeyFetches()
        var reads: [String] = []
        func read(_ name: String) async throws -> String? {
            reads.append(name)
            if reads.count == 1 { throw SSHFailure.unreachable("coupure") }
            return secret
        }

        let failed = await fetches.fetch(profile: "cyber", into: &store, read: read)
        XCTAssertNil(failed)
        // le même refus ne relit pas
        let sameRefusal = await fetches.fetch(profile: "cyber", into: &store, read: read)
        XCTAssertNil(sameRefusal)
        XCTAssertEqual(reads, ["cyber"])

        fetches.reset()
        let retried = await fetches.fetch(profile: "cyber", into: &store, read: read)
        XCTAssertEqual(retried, secret)
        XCTAssertEqual(reads, ["cyber", "cyber"])
        XCTAssertEqual(try store.apiKey(profile: "cyber"), secret)

        // un profil qui a répondu rouvre sa lecture sans toucher aux autres
        _ = await fetches.fetch(profile: "sport", into: &store, read: read)
        fetches.settle("cyber")
        _ = await fetches.fetch(profile: "cyber", into: &store, read: read)
        _ = await fetches.fetch(profile: "sport", into: &store, read: read)
        XCTAssertEqual(reads, ["cyber", "cyber", "sport", "cyber"])
    }

    func testAHeldKeyThatHermesRefusesIsNotReportedAsMissing() {
        XCTAssertTrue(HermesAPIKey.unauthorizedMessage(profile: "cyber", holdsKey: true).contains("clé API est refusée pour le profil cyber"))
        XCTAssertEqual(HermesAPIKey.unauthorizedMessage(profile: "cyber", holdsKey: false), HermesAPIKey.missingMessage(profile: "cyber"))
    }

    func testANamedProfileWithoutAKeyShowsTheMissingBannerAndNeverSendsTheDefaultKey() async throws {
        let defaultKey = "default-host-key-VALUE"
        var store = InMemorySecretStore(apiKey: defaultKey)
        var fetched: [String] = []
        let recovered = try await APIKeyRecovery.refresh(profile: "sport", into: &store) { name in
            fetched.append(name)
            XCTAssertNotEqual(name, "default")
            return name == "default" ? defaultKey : nil
        }
        XCTAssertNil(recovered)
        XCTAssertEqual(fetched, ["sport"])
        XCTAssertNil(try store.resolvedAPIKey(profile: "sport"))
        XCTAssertEqual(try store.resolvedAPIKey(profile: "default"), defaultKey)
        XCTAssertNil(try store.apiKey(profile: "sport"))

        let message = HermesAPIKey.missingMessage(profile: "sport")
        XCTAssertEqual(message, "Clé API introuvable sur l'hôte pour le profil sport.")
        XCTAssertFalse(message.contains(defaultKey))

        let finalStore = store
        let api = ResumeAPI(baseURL: URL(string: "http://hermes.invalid")!, apiKey: defaultKey, apiKeyForProfile: { try finalStore.resolvedAPIKey(profile: $0) })
        let request = try api.makeRequest(profile: "sport", input: "bonjour", session: "s", model: nil, key: "idem")
        XCTAssertEqual(request.url?.path, "/p/sport/v1/runs")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(try api.authorization(for: "sport"))
    }

    func testPersoHermesStaysRefusedWhenBuildingAPIKeyArgumentsInTestMode() {
        XCTAssertThrowsError(try SSHTunnelConfig(alias: "perso-hermes.invalid", hostname: "gateway.invalid", user: "operator", refusePersoHermes: true).apiKeyArguments(profile: "cyber")) {
            XCTAssertEqual($0 as? SSHFailure, .forbiddenHost)
        }
    }

    func testPersoHermesIsRefusedInTestModeOnTheAliasAndOnTheResolvedHost() {
        for alias in ["perso-hermes.invalid", "PERSO-HERMES.INVALID", "perso-hermes-alias.invalid"] {
            XCTAssertThrowsError(try config(alias: alias, hostname: "gateway.invalid"), alias) { XCTAssertEqual($0 as? SSHFailure, .forbiddenHost, alias) }
        }
        XCTAssertThrowsError(try config(alias: "lab.invalid", hostname: "ssh.perso-hermes.invalid")) {
            XCTAssertEqual($0 as? SSHFailure, .forbiddenHost)
        }
    }

    func testPersoHermesIsAllowedOutsideTestMode() throws {
        XCTAssertEqual(try config(alias: "perso-hermes.invalid", hostname: "perso-hermes.invalid", refuse: false).alias, "perso-hermes.invalid")
    }

    func testAliasAndPortAreValidatedBeforeAnyArgumentIsBuilt() {
        for alias in ["", " ", "-oProxyCommand=id", "a b", "host;id", "host\nid", "ho$st"] {
            XCTAssertThrowsError(try config(alias: alias), alias) { XCTAssertEqual($0 as? SSHFailure, .invalidHost, alias) }
        }
        for port in [0, -1, 65536] {
            XCTAssertThrowsError(try SSHTunnelConfig(alias: "lab.invalid", hostname: "gateway.invalid", user: "u", sshPort: port, refusePersoHermes: true), "\(port)") {
                XCTAssertEqual($0 as? SSHFailure, .invalidPort)
            }
        }
    }

    func testAnIPv6LiteralIsAValidResolvedHost() throws {
        XCTAssertEqual(try config(hostname: "::1").hostname, "::1")
    }

    func testOnlyAnUnreachableHostIsRetried() {
        XCTAssertEqual(SSHFailure.classify(stderr: "operator@gateway.invalid: Permission denied (publickey)."), .wrongKey)
        XCTAssertEqual(SSHFailure.classify(stderr: "sign_and_send_pubkey: signing failed for ed25519 from agent: agent refused operation"), .agentLockedOrEmpty)
        XCTAssertEqual(SSHFailure.classify(stderr: "Could not open a connection to your authentication agent"), .agentLockedOrEmpty)
        XCTAssertEqual(SSHFailure.classify(stderr: "Certificate invalid: expired"), .certificateExpired)
        XCTAssertEqual(SSHFailure.classify(stderr: "Host key verification failed."), .hostKeyChanged)
        XCTAssertEqual(SSHFailure.classify(stderr: "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@"), .hostKeyChanged)
        XCTAssertEqual(SSHFailure.classify(stderr: "ssh: connect to host gateway.invalid port 22: Connection refused\n"), .unreachable("ssh: connect to host gateway.invalid port 22: Connection refused"))
        XCTAssertEqual(SSHFailure.classify(stderr: ""), .unreachable(""))
        let retried = [SSHFailure.unreachable("x")].filter(\.retries)
        XCTAssertEqual(retried.count, 1)
        for terminal in [SSHFailure.wrongKey, .hostKeyChanged, .unknownAlias, .matchBlockRefused, .unreadableConfig, .agentLockedOrEmpty, .certificateExpired, .forbiddenHost, .relayRefused, .invalidHost, .invalidPort] {
            XCTAssertFalse(terminal.retries, "\(terminal)")
        }
    }

    func testTheRelayRefusalBannerNamesTheRelayKeywordsAndNoMode() {
        let text = SSHFailure.relayRefused.message
        XCTAssertEqual(text, "Cet alias passe par un relais (ProxyJump ou ProxyCommand). Hermed Bots le refuse : utilise un alias qui se connecte directement à l'hôte.")
        XCTAssertFalse(text.contains("mode test"))
        XCTAssertFalse(text.contains("docs/"))
    }

    func testTheConfigRefusalBannersNameTheCauseAndTheWayOut() {
        XCTAssertEqual(
            SSHFailure.matchBlockRefused.message,
            "Ta config SSH contient un bloc Match. Hermed Bots ne l'interprète pas et refuse l'alias : remplace le bloc Match par des blocs Host."
        )
        XCTAssertEqual(
            SSHFailure.unreadableConfig.message,
            "Hermed Bots ne lit pas cette config SSH avec certitude : erreur de syntaxe, Include sans fichier ou journal trop long. L'alias est refusé."
        )
    }

    func testTheForbiddenHostBannerNamesNoMachine() {
        let text = SSHFailure.forbiddenHost.message
        XCTAssertEqual(text, "Cet hôte est refusé en mode test.")
        XCTAssertFalse(text.contains("docs/"))
        XCTAssertEqual(SSHFailure.unknownAlias.message, "Cet alias SSH est inconnu.")
        XCTAssertEqual(SSHFailure.agentLockedOrEmpty.message, "L'agent SSH est verrouillé ou vide.")
        XCTAssertEqual(SSHFailure.certificateExpired.message, "Le certificat SSH a expiré.")
        XCTAssertTrue(SSHFailure.wrongKey.message.contains("refuse l'identité"))
        XCTAssertFalse(SSHFailure.wrongKey.message.contains("Trousseau"))
    }

    func testTheChildEnvironmentTakesTheSessionAgentAndNeverInheritsATestKey() async throws {
        let environment = SSHChildEnvironment.make([
            "HV_TEST_SSH_KEY": "SECRETMATERIAL0123456789",
            "SSH_AUTH_SOCK": "/tmp/example-agent.invalid",
            "HOME": "/tmp/example-home",
            "PATH": "/evil",
        ])
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(environment["LC_ALL"], "C")
        XCTAssertEqual(environment["SSH_AUTH_SOCK"], "/tmp/example-agent.invalid")
        XCTAssertEqual(environment["HOME"], "/tmp/example-home")
        XCTAssertNil(environment["HV_TEST_SSH_KEY"])
        let result = try await Spawn.run("/usr/bin/env", [], environment: ["ONLY": "this"], timeout: .seconds(5))
        XCTAssertEqual(result.stdout, "ONLY=this\n")
        XCTAssertFalse(result.stdout.contains("SECRETMATERIAL"))
    }

    func testStdoutIsCapturedInFullWhileStderrKeepsOnlyItsStart() async throws {
        // 16 Kio sur chaque sortie : la table de `hermes profile list` de 40 profils fait plus de 14 Kio et ne doit jamais être coupée
        let script = "dd if=/dev/zero bs=1024 count=16 2>/dev/null | tr '\\0' x; dd if=/dev/zero bs=1024 count=16 2>/dev/null | tr '\\0' e >&2"
        let result = try await Spawn.run("/bin/sh", ["-c", script], environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(10))
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.utf8.count, 16 * 1024)
        XCTAssertEqual(result.stderr.utf8.count, 8192)
    }
}

final class ProcessGroupTests: XCTestCase {
    private func gone(_ group: pid_t) async -> Bool {
        for _ in 0..<60 {
            if killpg(group, 0) == -1, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    func testTerminatingTheGroupLeavesNoDescendant() async throws {
        // un shell qui lance deux sleep : tuer le seul shell laisserait les deux sleep vivants
        let child = try Spawn.start("/bin/sh", ["-c", "sleep 60 & sleep 60 & wait"], environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(child.group, child.pid)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(killpg(child.group, 0), 0, "le groupe doit vivre avant l'arrêt")
        // SIGTERM seul doit suffire : si le signal n'atteignait que le chef, le SIGKILL de repli ne partirait qu'après les 5 s de grâce
        let started = ContinuousClock.now
        await ProcessGroups.terminate(child.group, grace: .seconds(5))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2), "SIGTERM n'a pas atteint tout le groupe")
        let wasGone = await gone(child.group)
        XCTAssertTrue(wasGone, "un processus du groupe a survécu")
    }

    func testAMemberThatIgnoresSigtermIsKilledAfterTheGrace() async throws {
        let child = try Spawn.start("/bin/sh", ["-c", "trap '' TERM; while :; do sleep 1; done"], environment: ["PATH": "/usr/bin:/bin"])
        try await Task.sleep(for: .milliseconds(300))
        await ProcessGroups.terminate(child.group, grace: .milliseconds(300))
        let wasGone = await gone(child.group)
        XCTAssertTrue(wasGone)
    }

    func testAChildJoinsTheGroupOfItsLeader() async throws {
        let leader = try Spawn.start("/bin/sleep", ["60"], environment: [:])
        let member = try Spawn.start("/bin/sleep", ["60"], environment: [:], joining: leader.group)
        XCTAssertEqual(getpgid(member.pid), leader.group)
        await ProcessGroups.terminate(leader.group, grace: .seconds(1))
        let exit = await member.waitForExit()
        XCTAssertNotEqual(exit, 0)
    }

    func testTheWatchdogKillsTheWholeGroupWhenTheAppSideDisappears() async throws {
        // le chef du groupe lit un tube que seule l'app tient ouvert : si l'app meurt, même par SIGKILL, le noyau ferme le tube
        let watchdog = try Spawn.startWatchdog()
        let member = try Spawn.start("/bin/sleep", ["60"], environment: [:], joining: watchdog.pid)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(killpg(watchdog.group, 0), 0, "le groupe doit vivre tant que le tube est ouvert")
        XCTAssertFalse(member.hasExited)
        watchdog.closeStdin()
        let wasGone = await gone(watchdog.group)
        XCTAssertTrue(wasGone, "le gardien n'a pas tué le groupe")
        let exit = await member.waitForExit()
        XCTAssertEqual(exit, -SIGKILL)
    }

    func testTheWatchdogAlsoRemovesTheTunnelDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hb-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        for name in ["a", "key.pub", "known_hosts"] { FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: Data()) }
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let watchdog = try Spawn.startWatchdog(cleaning: directory)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        watchdog.closeStdin()
        let wasGone = await gone(watchdog.group)
        XCTAssertTrue(wasGone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "le dossier privé du tunnel a survécu à l'app")
    }

    func testTheWatchdogLeavesTheGroupAloneWhileThePipeIsOpen() async throws {
        let watchdog = try Spawn.startWatchdog()
        let member = try Spawn.start("/bin/sleep", ["60"], environment: [:], joining: watchdog.pid)
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(member.hasExited)
        XCTAssertFalse(watchdog.hasExited)
        await ProcessGroups.terminate(watchdog.group, grace: .seconds(1))
        let wasGone = await gone(watchdog.group)
        XCTAssertTrue(wasGone)
    }

    func testTheRegistryKillsEveryGroupAtTermination() async throws {
        let child = try Spawn.start("/bin/sleep", ["60"], environment: [:])
        ProcessGroups.register(child.group)
        ProcessGroups.killAll()
        let wasGone = await gone(child.group)
        XCTAssertTrue(wasGone)
    }
}

/// `ssh -G` avec un `Match exec` reste en vie tant que la commande dort : l'arrêt de l'app doit l'atteindre
final class GuardedSpawnTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hb-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func processID(in file: URL) async throws -> pid_t {
        for _ in 0..<100 {
            if let text = try? String(contentsOf: file, encoding: .utf8), let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                addTeardownBlock { kill(value, SIGKILL) }
                return value
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw XCTSkip("le processus n'a pas écrit son identifiant")
    }

    private func gone(_ pid: pid_t) async -> Bool {
        for _ in 0..<60 {
            if kill(pid, 0) == -1, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    func testTerminatingTheAppLeavesNoSshDumpAlive() async throws {
        let directory = try temporaryDirectory()
        let pidFile = directory.appendingPathComponent("pid")
        let config = directory.appendingPathComponent("config")
        try "Match exec \"echo $$ > \(pidFile.path); exec sleep 30\"\nHost lab.invalid\n".write(to: config, atomically: true, encoding: .utf8)
        let resolver = SystemSSHConfigResolver(configFile: config.path)
        let dump = Task { try await resolver.dump(alias: "lab.invalid", invocation: .tunnel) }
        let sleeper = try await processID(in: pidFile)
        XCTAssertEqual(kill(sleeper, 0), 0, "la commande du Match exec doit vivre avant l'arrêt")
        ProcessGroups.killAll()
        let started = ContinuousClock.now
        _ = await dump.result
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2), "ssh -G a survécu à l'arrêt")
        let wasGone = await gone(sleeper)
        XCTAssertTrue(wasGone, "la commande du Match exec a survécu à l'arrêt")
    }

    func testATimedOutGuardedRunKillsEveryProcessOfItsGroup() async throws {
        let pidFile = try temporaryDirectory().appendingPathComponent("pid")
        // un petit-enfant qui garde la sortie d'erreur ouverte : tuer le seul shell laisserait l'appel attendre ses 30 s
        let script = "sleep 30 & echo $! > \(pidFile.path); wait"
        let started = ContinuousClock.now
        do {
            _ = try await Spawn.runGuarded("/bin/sh", ["-c", script], environment: ["PATH": "/usr/bin:/bin"], timeout: .milliseconds(500))
            XCTFail("le délai devait expirer")
        } catch SpawnError.timedOut {}
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "l'appel a attendu le petit-enfant")
        let grandchild = try await processID(in: pidFile)
        let wasGone = await gone(grandchild)
        XCTAssertTrue(wasGone, "le petit-enfant a survécu au délai")
    }

    func testAGuardedRunLeavesNoProcessGroupBehind() async throws {
        let output = try await Spawn.runGuarded("/bin/sh", ["-c", "ps -o pgid= -p $$"], environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(5))
        let group = try XCTUnwrap(pid_t(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertNotEqual(group, getpgrp(), "le processus doit tourner dans son propre groupe")
        var remaining = true
        for _ in 0..<60 where remaining {
            remaining = !(killpg(group, 0) == -1 && errno == ESRCH)
            if remaining { try await Task.sleep(for: .milliseconds(50)) }
        }
        XCTAssertFalse(remaining, "le gardien du groupe a survécu à l'appel")
    }
}

@MainActor
final class SSHTunnelSupervisorTests: XCTestCase {
    private let config = try! SSHTunnelConfig(alias: "lab.invalid", hostname: "gateway.invalid", user: "operator", refusePersoHermes: true)

    private func eventually(_ what: String, timeout: TimeInterval = 3, _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition jamais vraie : \(what)")
    }

    func testAWrongKeyStopsAfterOneAttempt() async {
        let backend = FakeBackend([.fail(.wrongKey)])
        let tunnel = SSHTunnel(delays: [.milliseconds(10)])
        tunnel.start(config, backend: backend)
        await eventually("failed(wrongKey)") { tunnel.state == .failed(.wrongKey) }
        // si une relance existait, le délai de 10 ms l'aurait déjà lancée
        try? await Task.sleep(for: .milliseconds(300))
        let opens = await backend.opens
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(tunnel.state, .failed(.wrongKey))
    }

    func testAChangedHostKeyIsNotRetried() async {
        let backend = FakeBackend([.fail(.hostKeyChanged)])
        let tunnel = SSHTunnel(delays: [.milliseconds(10)])
        tunnel.start(config, backend: backend)
        await eventually("failed(hostKeyChanged)") { tunnel.state == .failed(.hostKeyChanged) }
        try? await Task.sleep(for: .milliseconds(200))
        let opens = await backend.opens
        XCTAssertEqual(opens, 1)
    }

    func testADroppedTunnelReopensWithoutUserAction() async {
        let backend = FakeBackend([.session(port: 40001), .session(port: 40002)])
        let tunnel = SSHTunnel(delays: [.milliseconds(10)])
        tunnel.start(config, backend: backend)
        await eventually("open(40001)") { tunnel.state == .open(localPort: 40001) }
        await backend.drop(stderr: "Connection reset by peer")
        await eventually("open(40002)") { tunnel.state == .open(localPort: 40002) }
        let opens = await backend.opens
        XCTAssertEqual(opens, 2)
    }

    func testAnUnreachableHostIsRetriedWithTheDelaysThenOpens() async {
        let backend = FakeBackend([.fail(.unreachable("down")), .fail(.unreachable("down")), .session(port: 40003)])
        let tunnel = SSHTunnel(delays: [.milliseconds(10), .milliseconds(20)])
        tunnel.start(config, backend: backend)
        await eventually("open(40003)") { tunnel.state == .open(localPort: 40003) }
        let opens = await backend.opens
        XCTAssertEqual(opens, 3)
    }

    func testTheStateShowsTheReopeningAttempt() async {
        let backend = FakeBackend([.fail(.unreachable("down")), .session(port: 40004)], gate: true)
        let tunnel = SSHTunnel(delays: [.milliseconds(10)])
        tunnel.start(config, backend: backend)
        await eventually("reopening(1)") { tunnel.state == .reopening(attempt: 1) }
        await backend.openGate()
        await eventually("open(40004)") { tunnel.state == .open(localPort: 40004) }
    }

    func testAWrongKeyReportedAfterTheTunnelWasOpenIsNotRetried() async {
        let backend = FakeBackend([.session(port: 40005)])
        let tunnel = SSHTunnel(delays: [.milliseconds(10)])
        tunnel.start(config, backend: backend)
        await eventually("open") { tunnel.state == .open(localPort: 40005) }
        await backend.drop(stderr: "hvssh@h: Permission denied (publickey).")
        await eventually("failed(wrongKey)") { tunnel.state == .failed(.wrongKey) }
    }

    func testStopClosesTheBackendAndNothingReopens() async {
        let backend = FakeBackend([.session(port: 40006), .session(port: 40007)])
        let tunnel = SSHTunnel(delays: [.milliseconds(10)])
        tunnel.start(config, backend: backend)
        await eventually("open") { tunnel.state == .open(localPort: 40006) }
        await tunnel.stop()
        XCTAssertEqual(tunnel.state, .idle)
        try? await Task.sleep(for: .milliseconds(200))
        let (opens, closes) = await (backend.opens, backend.closes)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(tunnel.state, .idle)
    }

    func testRefuseShowsTheFailureWithoutAnyBackend() async {
        let tunnel = SSHTunnel(delays: [.milliseconds(10)])
        tunnel.refuse(.forbiddenHost)
        XCTAssertEqual(tunnel.state, .failed(.forbiddenHost))
    }

    func testStartingAgainReplacesThePreviousTunnel() async {
        let first = FakeBackend([.session(port: 40008)])
        let second = FakeBackend([.session(port: 40009)])
        let tunnel = SSHTunnel(delays: [.milliseconds(10)])
        tunnel.start(config, backend: first)
        await eventually("open(40008)") { tunnel.state == .open(localPort: 40008) }
        tunnel.start(config, backend: second)
        await eventually("open(40009)") { tunnel.state == .open(localPort: 40009) }
        await eventually("first backend closed") { await first.closes == 1 }
    }

    func testAnOpenThatFinishesAfterStopLeavesNoResourceBehind() async {
        let backend = LateBackend()
        let tunnel = SSHTunnel(delays: [.milliseconds(10)])
        tunnel.start(config, backend: backend)
        await eventually("open started") { await backend.opening }
        await tunnel.stop()
        await backend.finishOpen()
        await eventually("late resource created") { await backend.created == 1 }
        await eventually("late resource released") { await backend.live == 0 }
        XCTAssertEqual(tunnel.state, .idle)
    }

    func testAnOpenThatFinishesAfterAReplacementLeavesNoResourceBehind() async {
        let slow = LateBackend()
        let next = FakeBackend([.session(port: 40010)])
        let tunnel = SSHTunnel(delays: [.milliseconds(10)])
        tunnel.start(config, backend: slow)
        await eventually("open started") { await slow.opening }
        tunnel.start(config, backend: next)
        await eventually("open(40010)") { tunnel.state == .open(localPort: 40010) }
        await slow.finishOpen()
        await eventually("late resource created") { await slow.created == 1 }
        await eventually("late resource released") { await slow.live == 0 }
        XCTAssertEqual(tunnel.state, .open(localPort: 40010))
    }
}

final class SystemSSHBackendTests: XCTestCase {
    private let config = try! SSHTunnelConfig(alias: "lab.invalid", hostname: "127.0.0.1", user: "operator", sshPort: 1, refusePersoHermes: true)

    func testOpeningAfterCloseStartsNothing() async throws {
        let backend = SystemSSHBackend(environment: ["PATH": "/usr/bin:/bin"])
        await backend.close()
        do {
            _ = try await backend.open(config)
            XCTFail("open() a réussi après close()")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }
}

/// Un faux ssh : joue une liste d'issues dans l'ordre, une par `open`
private actor FakeBackend: SSHBackend {
    enum Step {
        case fail(SSHFailure)
        case session(port: Int)
    }

    private var steps: [Step]
    private var gate: CheckedContinuation<Void, Never>?
    private var gated: Bool
    private var exit: CheckedContinuation<SSHExit, Never>?
    private(set) var opens = 0
    private(set) var closes = 0

    init(_ steps: [Step], gate: Bool = false) {
        self.steps = steps
        gated = gate
    }

    func openGate() {
        gated = false
        gate?.resume()
        gate = nil
    }

    func open(_ config: SSHTunnelConfig) async throws -> SSHSession {
        opens += 1
        if gated, opens > 1 { await withCheckedContinuation { gate = $0 } }
        guard !steps.isEmpty else { throw SSHFailure.unreachable("plus d'issue prévue") }
        switch steps.removeFirst() {
        case .fail(let failure): throw failure
        case .session(let port): return SSHSession(localPort: port) { await self.waitForDrop() }
        }
    }

    private func waitForDrop() async -> SSHExit {
        await withCheckedContinuation { exit = $0 }
    }

    func drop(stderr: String) async {
        while exit == nil { await Task.yield() }
        exit?.resume(returning: SSHExit(status: 255, stderr: stderr))
        exit = nil
    }

    func close() async {
        closes += 1
        exit?.resume(returning: SSHExit(status: -15, stderr: ""))
        exit = nil
    }
}

/// Un faux ssh lent : `open` attend `finishOpen()` puis crée sa ressource ; `close()` ne libère que les ressources déjà créées
private actor LateBackend: SSHBackend {
    private var gate: CheckedContinuation<Void, Never>?
    private var finished = false
    private(set) var opening = false
    private(set) var created = 0
    private(set) var live = 0

    func finishOpen() {
        finished = true
        gate?.resume()
        gate = nil
    }

    func open(_ config: SSHTunnelConfig) async throws -> SSHSession {
        opening = true
        if !finished { await withCheckedContinuation { gate = $0 } }
        created += 1
        live += 1
        return SSHSession(localPort: 40100) { SSHExit(status: 0, stderr: "") }
    }

    func close() {
        live = 0
    }
}
