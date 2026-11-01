import Darwin
import XCTest

// compilé dans le paquet de tests lui-même, sans l'app comme hôte : aucun test ici n'ouvre de connexion réseau
final class SSHTunnelConfigTests: XCTestCase {
    private func config(alias: String = "lab.invalid", hostname: String = "gateway.invalid", refuse: Bool = true) throws -> SSHTunnelConfig {
        try SSHTunnelConfig(alias: alias, hostname: hostname, user: "operator", refuseTestHost: refuse)
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
        let ephemeral = SSHTunnelConfig.withIdentityAgent(args, socket: "/tmp/example-agent.invalid")
        XCTAssertEqual(ephemeral.indices.filter { ephemeral[$0] == "-o" }.map { ephemeral[$0 + 1] }.first, "IdentityAgent=\"/tmp/example-agent.invalid\"")
        XCTAssertEqual(ephemeral.last, "lab.invalid")
    }

    func testIdentityAgentQuotesASocketPathThatContainsSpaces() throws {
        let args = try config().arguments(localPort: 1)
        let socket = "/tmp/example agent.invalid/a"
        let quoted = SSHTunnelConfig.withIdentityAgent(args, socket: socket)
        XCTAssertEqual(
            quoted.indices.filter { quoted[$0] == "-o" }.map { quoted[$0 + 1] }.first,
            "IdentityAgent=\"\(socket)\""
        )
    }

    func testANonDefaultResolvedPortIsNotPassedAsDashP() throws {
        let config = try SSHTunnelConfig(
            alias: "example.invalid",
            hostname: "example.invalid",
            user: "operator",
            sshPort: 2200,
            refuseTestHost: true
        )
        let args = config.arguments(localPort: 1)
        XCTAssertEqual(config.sshPort, 2200)
        XCTAssertEqual(args.last, "example.invalid")
        XCTAssertNil(args.firstIndex(of: "-p"))
    }

    func testTheProfileListReadRunsOnlyHermesProfileListWithNoForward() throws {
        let args = try config().profileListArguments()
        XCTAssertEqual(Array(args.suffix(2)), ["lab.invalid", "sh -lc 'echo; echo HERMED_BOTS_REPLY; hermes profile list'"])
        for absent in ["-N", "-L", "-R", "-D", "-F", "-i", "-l", "-p"] { XCTAssertFalse(args.contains(absent), absent) }
        for required in ["-T", "BatchMode=yes", "ForwardAgent=no", "ControlMaster=no", "ControlPath=none", "ConnectTimeout=5"] {
            XCTAssertTrue(args.contains(required), required)
        }
    }

    func testTheProfileLocksReadRunsOneFixedRemoteCommandWithNoForward() throws {
        let args = try config().profileLocksArguments()
        XCTAssertEqual(Array(args.suffix(2)), ["lab.invalid", ProfileLock.command])
        for absent in ["-N", "-L", "-R", "-D", "-F", "-i", "-l", "-p"] { XCTAssertFalse(args.contains(absent), absent) }
        XCTAssertEqual(Array(args.dropLast(2)), Array(try config().profileListArguments().dropLast(2)))
    }

    func testTheAPIKeyReadRunsOnlyTheFrozenHermesConfigGetWithTheSameAlias() throws {
        let args = try config().apiKeyArguments(profile: "cyber")
        XCTAssertEqual(Array(args.suffix(2)), ["lab.invalid", "sh -lc 'echo; echo HERMED_BOTS_REPLY; hermes -p cyber config get API_SERVER_KEY --raw'"])
        XCTAssertEqual(HermesAPIKey.remoteCommand(profile: "cyber"), ["hermes", "-p", "cyber", "config", "get", "API_SERVER_KEY", "--raw"])
        for absent in ["-N", "-L", "-R", "-D", "-F", "-i", "-l"] { XCTAssertFalse(args.contains(absent), absent) }
        // le `-p` de hermes est dans la chaîne distante : ssh lui-même n'en reçoit aucun
        XCTAssertFalse(args.contains("-p"))
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

        let failed = try await fetches.fetch(profile: "cyber", into: &store, read: read)
        XCTAssertNil(failed)
        // le même refus ne relit pas
        let sameRefusal = try await fetches.fetch(profile: "cyber", into: &store, read: read)
        XCTAssertNil(sameRefusal)
        XCTAssertEqual(reads, ["cyber"])

        fetches.reset()
        let retried = try await fetches.fetch(profile: "cyber", into: &store, read: read)
        XCTAssertEqual(retried, secret)
        XCTAssertEqual(reads, ["cyber", "cyber"])
        XCTAssertEqual(try store.apiKey(profile: "cyber"), secret)

        // un profil qui a répondu rouvre sa lecture sans toucher aux autres
        _ = try await fetches.fetch(profile: "sport", into: &store, read: read)
        fetches.settle("cyber")
        _ = try await fetches.fetch(profile: "cyber", into: &store, read: read)
        _ = try await fetches.fetch(profile: "sport", into: &store, read: read)
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

    func testExampleHostStaysRefusedWhenBuildingAPIKeyArgumentsInTestMode() {
        XCTAssertThrowsError(try SSHTunnelConfig(alias: "example-host.invalid", hostname: "gateway.invalid", user: "operator", refuseTestHost: true).apiKeyArguments(profile: "cyber")) {
            XCTAssertEqual($0 as? SSHFailure, .forbiddenHost)
        }
    }

    func testExampleHostIsRefusedInTestModeOnTheAliasAndOnTheResolvedHost() {
        for alias in ["example-host.invalid", "EXAMPLE-HOST.INVALID", "example-host-alias.invalid"] {
            XCTAssertThrowsError(try config(alias: alias, hostname: "gateway.invalid"), alias) { XCTAssertEqual($0 as? SSHFailure, .forbiddenHost, alias) }
        }
        XCTAssertThrowsError(try config(alias: "lab.invalid", hostname: "ssh.example-host.invalid")) {
            XCTAssertEqual($0 as? SSHFailure, .forbiddenHost)
        }
    }

    func testExampleHostIsAllowedOutsideTestMode() throws {
        XCTAssertEqual(try config(alias: "example-host.invalid", hostname: "example-host.invalid", refuse: false).alias, "example-host.invalid")
    }

    func testAliasAndPortAreValidatedBeforeAnyArgumentIsBuilt() {
        for alias in ["", " ", "-oProxyCommand=id", "a b", "host;id", "host\nid", "ho$st"] {
            XCTAssertThrowsError(try config(alias: alias), alias) { XCTAssertEqual($0 as? SSHFailure, .invalidHost, alias) }
        }
        for port in [0, -1, 65536] {
            XCTAssertThrowsError(try SSHTunnelConfig(alias: "lab.invalid", hostname: "gateway.invalid", user: "u", sshPort: port, refuseTestHost: true), "\(port)") {
                XCTAssertEqual($0 as? SSHFailure, .invalidPort)
            }
        }
    }

    func testAnIPv6LiteralIsAValidResolvedHost() throws {
        XCTAssertEqual(try config(hostname: "::1").hostname, "::1")
    }

    func testOnlyAnUnreachableHostIsRetried() {
        XCTAssertEqual(SSHFailure.classify(stderr: "operator@gateway.invalid: Permission denied (publickey).", status: 255), .wrongKey(""))
        XCTAssertEqual(SSHFailure.classify(stderr: "sign_and_send_pubkey: signing failed for ed25519 from agent: agent refused operation", status: 255), .agentLockedOrEmpty(""))
        XCTAssertEqual(SSHFailure.classify(stderr: "Could not open a connection to your authentication agent", status: 255), .missingAgent)
        XCTAssertEqual(SSHFailure.classify(stderr: "Error connecting to agent: No such file or directory", status: 255), .missingAgent)
        XCTAssertEqual(SSHFailure.classify(stderr: "The agent has no identities.", status: 255), .missingKey)
        XCTAssertEqual(SSHFailure.classify(stderr: "Certificate invalid: expired", status: 255), .certificateExpired(""))
        XCTAssertEqual(SSHFailure.classify(stderr: "Host key verification failed.", status: 255), .hostKeyChanged(""))
        XCTAssertEqual(SSHFailure.classify(stderr: "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@", status: 255), .hostKeyChanged(""))
        XCTAssertEqual(SSHFailure.classify(stderr: "ssh: connect to host gateway.invalid port 22: Connection refused\n", status: 255), .unreachable("ssh: connect to host gateway.invalid port 22: Connection refused"))
        XCTAssertEqual(SSHFailure.classify(stderr: "", status: 255), .unreachable(""))
        XCTAssertEqual(SSHFailure.classify(stderr: "Connection reset by peer", status: 255), .tunnelClosed)
        XCTAssertEqual(SSHFailure.classify(stderr: "", status: 1), .tunnelClosed)
        XCTAssertEqual(SSHFailure.classify(stderr: "gate-wrapper_failure=17\n", status: 255), .wrapperFailure(name: "gate-wrapper", code: "17"))
        let retried = [SSHFailure.unreachable("")].filter(\.retries)
        XCTAssertEqual(retried.count, 1)
        for terminal in [SSHFailure.wrongKey(""), .hostKeyChanged(""), .unknownAlias, .unreadableConfig, .missingAgent, .missingKey, .missingWrapper, .noIdentity, .wrapperFailure(name: "gate-wrapper", code: "17"), .agentLockedOrEmpty(""), .certificateExpired(""), .forbiddenHost, .relayRefused, .routeMismatch, .invalidHost, .invalidPort, .tunnelClosed] {
            XCTAssertFalse(terminal.retries, "\(terminal)")
        }
    }

    func testStderrIsKeptInTheShownError() {
        let refused = "ssh: connect to host gateway.invalid port 22: Connection refused\n"
        let shown = SSHFailure.classify(stderr: refused, status: 255).message
        XCTAssertEqual(shown, SSHFailure.unreachable("").message + "\nssh: connect to host gateway.invalid port 22: Connection refused")
        XCTAssertTrue(shown.hasPrefix("Hôte injoignable. Vérifie le réseau, puis réessaie."))
        // sans sortie d'erreur, le message reste celui d'avant : rien n'est inventé
        XCTAssertEqual(SSHFailure.classify(stderr: " \n\n", status: 255).message, SSHFailure.unreachable("").message)
        XCTAssertEqual(SSHFailure.unreachable("").message, "Hôte injoignable. Vérifie le réseau, puis réessaie.")
        // le détail est borné : les trois dernières lignes, 400 caractères, sans caractère de contrôle
        let noisy = (1...10).map { "ligne \($0)" }.joined(separator: "\n") + "\n"
        XCTAssertEqual(SSHFailure.classify(stderr: noisy, status: 255), .unreachable("ligne 8\nligne 9\nligne 10"))
        let long = String(repeating: "x", count: 5_000)
        guard case .unreachable(let detail) = SSHFailure.classify(stderr: long, status: 255) else { return XCTFail("attendu unreachable") }
        XCTAssertEqual(detail.count, 400)
        XCTAssertTrue(detail.hasPrefix("…"))
        XCTAssertEqual(SSHFailure.classify(stderr: "boom\u{1B}[31m rouge\u{7}\n", status: 255), .unreachable("boom[31m rouge"))
        // une cause connue garde son texte fixe : la sortie brute de ssh n'y paraît pas
        for known in [
            "operator@gateway.invalid: Permission denied (publickey).",
            "Error connecting to agent: No such file or directory",
            "Host key verification failed.",
            "Certificate invalid: expired",
            "sign_and_send_pubkey: signing failed for ed25519 from agent: agent refused operation",
            "Connection reset by peer",
        ] {
            let failure = SSHFailure.classify(stderr: known, status: 255)
            XCTAssertFalse(failure.message.contains("\n"), known)
            XCTAssertFalse(failure.message.contains("gateway.invalid"), known)
            XCTAssertFalse(failure.message.contains("Permission denied"), known)
        }
    }

    func testAWrapperFailureLineGivesANamedMessage() {
        let failure = SSHFailure.classify(stderr: "debug: start\ngate-wrapper_failure=17\n", status: 255)
        XCTAssertEqual(failure, .wrapperFailure(name: "gate-wrapper", code: "17"))
        XCTAssertFalse(failure.retries)
        XCTAssertEqual(failure.message, "L'exécutable SSH a échoué : gate-wrapper (code 17). Le tunnel reste fermé.")
    }

    func testNoIdentityMessageNamesTheWayOut() {
        XCTAssertEqual(
            SSHFailure.noIdentity.message,
            "Aucune identité SSH n'est disponible. Charge une clé dans l'agent ou indique une commande de clé dans Réglages, puis réessaie."
        )
        XCTAssertFalse(SSHFailure.noIdentity.message.contains("publickey"))
        XCTAssertFalse(SSHFailure.noIdentity.message.contains("/"))
    }

    func testTheRelayRefusalBannerNamesTheRelayKeywordsAndNoMode() {
        let text = SSHFailure.relayRefused.message
        XCTAssertEqual(text, "Cet alias passe par un relais (ProxyJump ou ProxyCommand). Hermed Bots le refuse : utilise un alias qui se connecte directement à l'hôte.")
        XCTAssertFalse(text.contains("mode test"))
        XCTAssertFalse(text.contains("docs/"))
    }

    func testTheConfigRefusalBannersNameTheCauseAndTheWayOut() {
        XCTAssertEqual(
            SSHFailure.unreadableConfig.message,
            "ssh ne lit pas cette config SSH. L'alias est refusé."
        )
        XCTAssertFalse(SSHFailure.unreadableConfig.message.localizedCaseInsensitiveContains("Match"))
    }

    func testTheRouteMismatchBannerNamesNoMachine() {
        let text = SSHFailure.routeMismatch.message
        XCTAssertEqual(text, "La lecture de la clé ne vise pas le même hôte que le tunnel. La clé n'est pas lue.")
        XCTAssertFalse(text.localizedCaseInsensitiveContains("Match"))
        XCTAssertFalse(text.contains("docs/"))
    }

    func testTheForbiddenHostBannerNamesNoMachine() {
        let text = SSHFailure.forbiddenHost.message
        XCTAssertEqual(text, "Cet hôte est refusé en mode test.")
        XCTAssertFalse(text.contains("docs/"))
        XCTAssertEqual(SSHFailure.unknownAlias.message, "Cet alias SSH est inconnu.")
        XCTAssertEqual(SSHFailure.missingAgent.message, "L'agent SSH est absent. Démarre l'agent, puis réessaie.")
        XCTAssertEqual(SSHFailure.missingKey.message, "La clé SSH n'est pas chargée dans l'agent. Charge une identité dans l'agent, puis réessaie.")
        XCTAssertEqual(SSHFailure.missingWrapper.message, "L'exécutable SSH configuré est introuvable. Vérifie le chemin dans Réglages.")
        XCTAssertEqual(SSHFailure.agentLockedOrEmpty("").message, "L'agent SSH est verrouillé ou vide. Déverrouille-le ou charge une identité, puis réessaie.")
        XCTAssertFalse(SSHFailure.missingAgent.message.contains("publickey"))
        XCTAssertFalse(SSHFailure.missingKey.message.contains("publickey"))
        XCTAssertEqual(SSHFailure.certificateExpired("").message, "Le certificat SSH a expiré. Renouvelle-le, puis réessaie.")
        XCTAssertTrue(SSHFailure.wrongKey("").message.contains("refuse l'identité"))
        XCTAssertFalse(SSHFailure.wrongKey("").message.contains("Trousseau"))
        let denied = SSHFailure.classify(stderr: "operator@gateway.invalid: Permission denied (publickey).", status: 255)
        XCTAssertEqual(denied, .wrongKey(""))
        XCTAssertFalse(denied.message.contains("gateway.invalid"))
        XCTAssertFalse(denied.message.contains("Trousseau"))
        XCTAssertFalse(denied.message.contains("/"))
        XCTAssertEqual(SSHFailure.tunnelClosed.message, "Le serveur a fermé le tunnel. Réessaie la connexion.")
        XCTAssertEqual(SSHFailure.unreachable("").message, "Hôte injoignable. Vérifie le réseau, puis réessaie.")
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
        let tool = SSHChildEnvironment.forUserTool([
            "HV_TEST_SSH_KEY": "SECRETMATERIAL0123456789",
            "HV_API_URL": "http://127.0.0.1:1",
            "HOME": "/tmp/example-home",
            "PATH": "/usr/bin:/bin",
        ])
        XCTAssertNil(tool["HV_TEST_SSH_KEY"])
        XCTAssertNil(tool["HV_API_URL"])
        XCTAssertEqual(tool["HOME"], "/tmp/example-home")
        let result = try await Spawn.run("/usr/bin/env", [], environment: ["ONLY": "this"], timeout: .seconds(5))
        XCTAssertEqual(result.stdout, "ONLY=this\n")
        XCTAssertFalse(result.stdout.contains("SECRETMATERIAL"))
    }

    func testStdoutIsCapturedInFullWhileStderrKeepsOnlyItsEnd() async throws {
        // 16 Kio sur chaque sortie : la table de `hermes profile list` de 40 profils fait plus de 14 Kio et ne doit jamais être coupée
        let script = "dd if=/dev/zero bs=1024 count=16 2>/dev/null | tr '\\0' x; dd if=/dev/zero bs=1024 count=16 2>/dev/null | tr '\\0' e >&2; echo fin >&2"
        let result = try await Spawn.run("/bin/sh", ["-c", script], environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(10))
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.utf8.count, 16 * 1024)
        XCTAssertEqual(result.stderr.utf8.count, 8192)
        XCTAssertTrue(result.stderr.hasSuffix("efin\n"), "la fin de la sortie d'erreur est gardée, pas son début")
    }

    func testTheLastStderrLinesSurviveMoreThanTheBufferOfNoise() async throws {
        // 9 000 octets de bruit avant la ligne utile : le tampon (8 192 octets) ne garde que la fin
        let noise = "dd if=/dev/zero bs=1000 count=9 2>/dev/null | tr '\\0' x >&2; echo >&2"
        let wrapper = try await Spawn.run("/bin/sh", ["-c", noise + "; echo gate-wrapper_failure=17 >&2"], environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(10))
        XCTAssertEqual(SSHFailure.classify(stderr: wrapper.stderr, status: 255), .wrapperFailure(name: "gate-wrapper", code: "17"))
        let refused = try await Spawn.run("/bin/sh", ["-c", noise + "; echo 'ssh: connect to host gateway.invalid port 22: Connection refused' >&2"], environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(10))
        XCTAssertTrue(SSHFailure.classify(stderr: refused.stderr, status: 255).message.hasSuffix("port 22: Connection refused"))
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

    private func keyCommand(_ body: String) throws -> String {
        let path = try temporaryDirectory().appendingPathComponent("key-command").path
        try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    func testTheKeyCommandOutputIsTheKey() async throws {
        let path = try keyCommand("printf 'KEY-LINE\\n'")
        let key = try await CommandPrivateKeySource(path: path, environment: ["PATH": "/usr/bin:/bin"]).load()
        XCTAssertEqual(String(decoding: key, as: UTF8.self), "KEY-LINE\n")
    }

    func testTerminatingTheAppLeavesNoKeyCommandAlive() async throws {
        let pidFile = try temporaryDirectory().appendingPathComponent("pid")
        let path = try keyCommand("echo $$ > \(pidFile.path)\nexec sleep 30")
        let load = Task { try await CommandPrivateKeySource(path: path, environment: ["PATH": "/usr/bin:/bin"]).load() }
        let command = try await processID(in: pidFile)
        XCTAssertEqual(kill(command, 0), 0, "la commande de clé doit vivre avant l'arrêt")
        ProcessGroups.killAll()
        // avant d'attendre `load` : son délai de 8 s tuerait la commande même sans gardien
        let wasGone = await gone(command)
        XCTAssertTrue(wasGone, "la commande de clé a survécu à l'arrêt")
        _ = await load.result
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
    private let config = try! SSHTunnelConfig(alias: "lab.invalid", hostname: "gateway.invalid", user: "operator", refuseTestHost: true)

    private func eventually(_ what: String, timeout: TimeInterval = 3, _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition jamais vraie : \(what)")
    }

    private func failureMessage(of tunnel: SSHTunnel) -> String? {
        if case .failed(let failure) = tunnel.state { failure.message } else { nil }
    }

    func testAWrongKeyStopsAfterOneAttempt() async {
        let backend = FakeBackend([.fail(.wrongKey(""))])
        let tunnel = SSHTunnel(delays: [.milliseconds(10)])
        tunnel.start(config, backend: backend)
        await eventually("failed(wrongKey)") { tunnel.state == .failed(.wrongKey("")) }
        try? await Task.sleep(for: .milliseconds(300))
        let opens = await backend.opens
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(tunnel.state, .failed(.wrongKey("")))
    }

    func testAChangedHostKeyIsNotRetried() async {
        let backend = FakeBackend([.fail(.hostKeyChanged(""))])
        let tunnel = SSHTunnel(delays: [.milliseconds(10)])
        tunnel.start(config, backend: backend)
        await eventually("failed(hostKeyChanged)") { tunnel.state == .failed(.hostKeyChanged("")) }
        try? await Task.sleep(for: .milliseconds(200))
        let opens = await backend.opens
        XCTAssertEqual(opens, 1)
    }

    func testADroppedTunnelStaysClosedWhenTheServerStops() async {
        let backend = FakeBackend([.session(port: 40001), .session(port: 40002)])
        let tunnel = SSHTunnel(delays: [.milliseconds(10)])
        tunnel.start(config, backend: backend)
        await eventually("open(40001)") { tunnel.state == .open(localPort: 40001) }
        await backend.drop(stderr: "Connection reset by peer")
        await eventually("failed(tunnelClosed)") { tunnel.state == .failed(.tunnelClosed) }
        let opens = await backend.opens
        XCTAssertEqual(opens, 1)
    }

    func testADroppedTunnelReopensWithoutUserAction() async {
        let backend = FakeBackend([.session(port: 40001), .session(port: 40002)])
        let tunnel = SSHTunnel(delays: [.milliseconds(10)])
        tunnel.start(config, backend: backend)
        await eventually("open(40001)") { tunnel.state == .open(localPort: 40001) }
        await backend.drop(stderr: "ssh: connect to host gateway.invalid port 22: Connection refused\n")
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
        await eventually("failed(wrongKey)") { tunnel.state == .failed(.wrongKey("")) }
        await eventually("backend closed") { await backend.closes == 1 }
    }

    func testAnUnreachableOpenStopsAtTheReopenCap() async {
        // huit issues prévues, six ouvertures : le plafond arrête avant les deux dernières
        let fail = FakeBackend.Step.fail(.unreachable("down"))
        let backend = FakeBackend([FakeBackend.Step](repeating: fail, count: 8))
        let tunnel = SSHTunnel(delays: [.milliseconds(5)])
        tunnel.start(config, backend: backend)
        await eventually("failed(unreachable)") { tunnel.state == .failed(.unreachable("down")) }
        try? await Task.sleep(for: .milliseconds(200))
        let (opens, closes) = await (backend.opens, backend.closes)
        XCTAssertEqual(SSHTunnel.maxConsecutiveFailures, 6)
        XCTAssertEqual(opens, 6)
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(tunnel.state, .failed(.unreachable("down")))
    }

    func testTheReopenCapCountsOnlyConsecutiveFailures() async {
        // quatre échecs, une ouverture, la chute, quatre échecs, une ouverture : neuf échecs en tout, jamais six de suite
        let fail = FakeBackend.Step.fail(.unreachable("down"))
        let backend = FakeBackend([FakeBackend.Step](repeating: fail, count: 4) + [.session(port: 40021)] + [FakeBackend.Step](repeating: fail, count: 4) + [.session(port: 40022)])
        let tunnel = SSHTunnel(delays: [.milliseconds(5)])
        tunnel.start(config, backend: backend)
        await eventually("open(40021)") { tunnel.state == .open(localPort: 40021) }
        await backend.drop(stderr: "ssh: connect to host gateway.invalid port 22: Connection refused\n")
        await eventually("open(40022)") { tunnel.state == .open(localPort: 40022) }
        let opens = await backend.opens
        XCTAssertEqual(opens, 10)
    }

    func testWrapperFailureLineIsNamedAndNotRetried() async {
        let backend = FakeBackend([.session(port: 40023), .session(port: 40024)])
        let tunnel = SSHTunnel(delays: [.milliseconds(5)])
        tunnel.start(config, backend: backend)
        await eventually("open(40023)") { tunnel.state == .open(localPort: 40023) }
        await backend.drop(stderr: "gate-wrapper_failure=17\n")
        await eventually("failed(wrapperFailure)") { tunnel.state == .failed(.wrapperFailure(name: "gate-wrapper", code: "17")) }
        try? await Task.sleep(for: .milliseconds(150))
        let (opens, closes) = await (backend.opens, backend.closes)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(failureMessage(of: tunnel), "L'exécutable SSH a échoué : gate-wrapper (code 17). Le tunnel reste fermé.")
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
    private let config = try! SSHTunnelConfig(alias: "lab.invalid", hostname: "127.0.0.1", user: "operator", sshPort: 1, refuseTestHost: true)

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

    func testOpenOnAnInvalidAliasLaunchesSystemSshAndSurfacesItsStderr() async throws {
        let config = try SSHTunnelConfig(alias: "lab.invalid", hostname: "lab.invalid", user: "operator", refuseTestHost: true)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hb-ssh-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let backend = SystemSSHBackend(environment: [
            "PATH": "/usr/bin:/bin",
            "HOME": home.path,
            "USER": "operator",
            "LOGNAME": "operator",
        ])
        do {
            _ = try await backend.open(config)
            XCTFail("open() a réussi vers lab.invalid")
        } catch let failure as SSHFailure {
            XCTAssertFalse(failure.message.contains("Trousseau"), failure.message)
            XCTAssertFalse(failure.message.isEmpty)
            let args = config.arguments(localPort: 1)
            XCTAssertEqual(args.last, "lab.invalid")
            XCTAssertNil(args.firstIndex(of: "-i"))
            XCTAssertNil(args.firstIndex(of: "-F"))
            XCTAssertNil(args.firstIndex(of: "-l"))
        }
        await backend.close()
    }
}

/// Le mode Exécutable lance l'exécutable avec le PATH du shell de connexion de l'utilisateur : une app ouverte depuis le Finder ne reçoit que le PATH minimal de launchd
final class WrapperLoginPathTests: XCTestCase {
    private let config = try! SSHTunnelConfig(alias: "lab.invalid", hostname: "example.invalid", user: "operator", sshPort: 2200, refuseTestHost: true)
    private let home = "/tmp/example-home"
    private let launchdPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    private func script(_ body: String, name: String = "tool") throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hb-login-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent(name).path
        try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    /// Un exécutable qui écrit son PATH sur la sortie d'erreur puis échoue : `open()` rend ce PATH dans le détail de `unreachable`
    private func pathSeenByWrapper(_ backend: SystemSSHBackend) async throws -> String {
        defer { addTeardownBlock { await backend.close() } }
        do {
            _ = try await backend.open(config)
            XCTFail("open() a réussi avec un exécutable qui échoue")
        } catch let failure as SSHFailure {
            guard case .unreachable(let detail) = failure else { XCTFail("\(failure)"); return "" }
            return detail
        }
        return ""
    }

    private func backend(wrapper: String, loginShell: String?, timeout: Duration = .seconds(5)) -> SystemSSHBackend {
        SystemSSHBackend(
            environment: ["PATH": launchdPath, "HOME": home, "USER": "operator", "LOGNAME": "operator"],
            client: SSHClientSettings(authMode: .wrapper, wrapperPath: wrapper),
            loginPath: LoginPath(shell: loginShell, timeout: timeout)
        )
    }

    func testWrapperGetsALoginPath() async throws {
        let wrapper = try script(#"printf '%s\n' "$PATH" >&2; exit 255"#)
        // le shell écrit du bruit avant le PATH (un rc qui affiche) et refuse d'être lancé sans `-l`
        let shell = try script(#"[ "$1" = "-l" ] || exit 9; echo 'message du rc'; printf '%s\n' '/opt/example-login/bin:/usr/bin:/bin'"#, name: "login-shell")
        let seen = try await pathSeenByWrapper(backend(wrapper: wrapper, loginShell: shell))
        XCTAssertEqual(seen, "/opt/example-login/bin:/usr/bin:/bin")
    }

    func testWrapperPathFallsBackWhenLoginShellFails() async throws {
        let wrapper = try script(#"printf '%s\n' "$PATH" >&2; exit 255"#)
        let expected = launchdPath + ":/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:\(home)/.local/bin:\(home)/bin"
        let failing = try script("exit 1", name: "failing-shell")
        let silent = try script("printf ''", name: "silent-shell")
        let hanging = try script("sleep 30", name: "hanging-shell")
        for (name, shell) in [("échec", failing), ("sortie vide", silent), ("absent", "/tmp/example-shell.invalid")] {
            let seen = try await pathSeenByWrapper(backend(wrapper: wrapper, loginShell: shell))
            XCTAssertEqual(seen, expected, name)
        }
        // un shell qui ne rend pas la main est tué au délai
        let started = ContinuousClock.now
        let seen = try await pathSeenByWrapper(backend(wrapper: wrapper, loginShell: hanging, timeout: .milliseconds(300)))
        XCTAssertEqual(seen, expected, "délai")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10))
    }

    func testTheLoginPathIsReadOncePerBackend() async throws {
        let counter = FileManager.default.temporaryDirectory.appendingPathComponent("hb-login-count-\(UUID().uuidString.prefix(8))")
        addTeardownBlock { try? FileManager.default.removeItem(at: counter) }
        let shell = try script("echo run >> '\(counter.path)'; printf '%s\\n' '/opt/example-login/bin'", name: "counting-shell")
        let wrapper = try script(#"printf '%s\n' "$PATH" >&2; exit 255"#)
        let backend = backend(wrapper: wrapper, loginShell: shell)
        _ = try await pathSeenByWrapper(backend)
        let second = try await pathSeenByWrapper(backend)
        XCTAssertEqual(second, "/opt/example-login/bin")
        let runs = try String(contentsOf: counter, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(runs.count, 1)
    }

    func testTheSessionModeKeepsItsFixedPath() {
        let environment = SSHChildEnvironment.make(["PATH": "/opt/example-login/bin", "HOME": home])
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin")
    }
}

/// ssh envoie la commande distante au shell du compte de l'hôte, qui n'est ni interactif ni de connexion : le PATH que le profil de connexion ajoute n'y est pas
final class RemoteLoginShellTests: XCTestCase {
    private let outerShells = ["/bin/sh", "/bin/bash", "/bin/zsh"]

    private func config() throws -> SSHTunnelConfig {
        try SSHTunnelConfig(alias: "lab.invalid", hostname: "gateway.invalid", user: "operator", refuseTestHost: true)
    }

    /// Un HOME dont `.profile` ajoute `.local/bin` au PATH, où `tool` est un script : l'installation d'un outil dans un dossier bin personnel
    private func homeWithTool(_ tool: String, body: String, banner: String? = nil, terminated: Bool = true) throws -> String {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hb-remote-\(UUID().uuidString.prefix(8))")
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        // un profil bavard écrit sur stdout avant la commande : motd, conseil du jour, diagnostic
        // `terminated: false` : la dernière ligne de la bannière n'a pas de saut de ligne (printf sans \n)
        let chatter = banner.map { terminated ? "echo '\($0)'\n" : "printf '%s' '\($0)'\n" } ?? ""
        try "\(chatter)PATH=\"\(bin.path):$PATH\"\nexport PATH\n".write(to: home.appendingPathComponent(".profile"), atomically: true, encoding: .utf8)
        let path = bin.appendingPathComponent(tool).path
        try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return home.path
    }

    /// Ce que fait sshd : le shell du compte lance la chaîne reçue avec `-c`, sans PATH de connexion
    private func replay(_ remote: String, outer: String, home: String) async throws -> Spawn.Output {
        try await Spawn.run(outer, ["-c", remote], environment: ["PATH": "/usr/bin:/bin", "HOME": home, "LC_ALL": "C"], timeout: .seconds(10))
    }

    func testRemoteCommandRunsInALoginShell() async throws {
        let home = try homeWithTool("hermes", body: #"printf 'hermes %s\n' "$*""#)
        let list = try config().profileListArguments().last!
        let key = try config().apiKeyArguments(profile: "cyber").last!
        for outer in outerShells {
            let listed = try await replay(list, outer: outer, home: home)
            XCTAssertEqual(listed.status, 0, outer)
            XCTAssertEqual(RemoteShell.reply(listed.stdout), "hermes profile list\n", outer)
            let read = try await replay(key, outer: outer, home: home)
            XCTAssertEqual(RemoteShell.reply(read.stdout), "hermes -p cyber config get API_SERVER_KEY --raw\n", outer)
        }
        // la commande nue, telle que l'app l'envoyait, ne trouve pas l'outil : 127
        let bare = try await replay("hermes profile list", outer: "/bin/sh", home: home)
        XCTAssertEqual(bare.status, 127)
    }

    func testRemoteArgumentsAreQuotedInTheLoginShell() async throws {
        let canary = FileManager.default.temporaryDirectory.appendingPathComponent("hb-canary-\(UUID().uuidString.prefix(8))")
        addTeardownBlock { try? FileManager.default.removeItem(at: canary) }
        let home = try homeWithTool("tool", body: #"for a in "$@"; do printf '[%s]\n' "$a"; done"#)
        let hostile = ["a b", "it's", "$HOME", "x; touch \(canary.path)", "`touch \(canary.path)`", "", "ligne 1\nligne 2", "a\\b", "\"q\"", "*", "-p", "é"]
        let remote = RemoteShell.loginCommand(["tool"] + hostile)
        for outer in outerShells {
            let output = try await replay(remote, outer: outer, home: home)
            XCTAssertEqual(RemoteShell.reply(output.stdout), hostile.map { "[\($0)]\n" }.joined(), outer)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: canary.path), "un argument a été exécuté par le shell distant")
    }

    func testRemoteShellQuotingKeepsReadableWordsAndEscapesTheRest() {
        for plain in ["hermes", "-p", "--raw", "API_SERVER_KEY", "cyber.v2", "/usr/bin/x"] {
            XCTAssertEqual(RemoteShell.quote(plain), plain)
        }
        XCTAssertEqual(RemoteShell.quote(""), "''")
        XCTAssertEqual(RemoteShell.quote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(RemoteShell.quote("a b"), "'a b'")
        XCTAssertEqual(RemoteShell.loginCommand(["hermes", "a b"]), #"sh -lc 'echo; echo HERMED_BOTS_REPLY; hermes '\''a b'\'''"#)
    }

    func testAChattyLoginProfileDoesNotReplaceTheAPIKey() async throws {
        let secret = "profile-key-VALUE"
        let home = try homeWithTool("hermes", body: "printf '%s\\n' '\(secret)'", banner: "Welcome to the host")
        let key = try config().apiKeyArguments(profile: "cyber").last!
        for outer in outerShells {
            let read = try await replay(key, outer: outer, home: home)
            XCTAssertEqual(read.status, 0, outer)
            // sans l'isolation, la bannière est la première ligne : elle serait gardée comme clé
            XCTAssertEqual(HermesAPIKey.parse(read.stdout), "Welcome to the host", outer)
            XCTAssertEqual(HermesAPIKey.parse(RemoteShell.reply(read.stdout)), secret, outer)
        }
    }

    func testAnUnterminatedLoginBannerDoesNotReplaceTheAPIKey() async throws {
        let secret = "profile-key-VALUE"
        let home = try homeWithTool("hermes", body: "printf '%s\\n' '\(secret)'", banner: "Welcome to the host", terminated: false)
        let key = try config().apiKeyArguments(profile: "cyber").last!
        let list = try config().profileListArguments().last!
        for outer in outerShells {
            let read = try await replay(key, outer: outer, home: home)
            XCTAssertEqual(read.status, 0, outer)
            // sans le saut de ligne avant le marqueur, la bannière et le marqueur forment une seule ligne que `reply` ne reconnaît pas
            XCTAssertEqual(HermesAPIKey.parse(RemoteShell.reply(read.stdout)), secret, outer)
            let listed = try await replay(list, outer: outer, home: home)
            XCTAssertEqual(RemoteShell.reply(listed.stdout), "\(secret)\n", outer)
        }
    }

    func testTheReplyIsWhatFollowsTheLastMarkerLine() {
        let marker = "HERMED_BOTS_REPLY"
        XCTAssertEqual(RemoteShell.reply("bannière\n\(marker)\nclé\nreste\n"), "clé\nreste\n")
        XCTAssertEqual(RemoteShell.reply("\(marker)\n"), "")
        XCTAssertEqual(RemoteShell.reply("a\n\(marker)\nb\n\(marker)\nc\n"), "c\n")
        // une ligne qui contient le marqueur sans l'être n'isole rien ; sans marqueur, la sortie reste entière
        XCTAssertEqual(RemoteShell.reply("préfixe \(marker)\nclé\n"), "préfixe \(marker)\nclé\n")
        XCTAssertEqual(RemoteShell.reply("clé\n"), "clé\n")
        XCTAssertEqual(RemoteShell.reply(""), "")
    }

    /// Un exécutable qui tient le port du tunnel ouvert, puis répond aux lectures auxiliaires avec le code et la sortie d'erreur de `status`
    /// `stderr` remplace la sortie d'erreur d'une ligne que `status` donne après le code
    private func answeringWrapper(status: String, stdout: String = "", stderr: String? = nil, delay: Int = 0) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hb-answer-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let wrapper = dir.appendingPathComponent("wrapper").path
        try """
        #!/bin/sh
        forward=""
        for arg in "$@"; do
          case "$arg" in 127.0.0.1:*:127.0.0.1:*) forward="$arg" ;; esac
        done
        if [ -n "$forward" ]; then
          port=$(printf '%s' "$forward" | awk -F: '{print $2}')
          exec /usr/bin/python3 -c 'import socket,sys,time; p=int(sys.argv[1]); s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",p)); s.listen(1); s.settimeout(30); c,_=s.accept(); time.sleep(8)' "$port"
        fi
        sleep \(delay)
        cat "\(dir.path)/stdout"
        code=$(cut -d' ' -f1 "\(dir.path)/answer")
        if [ -f "\(dir.path)/stderr" ]; then cat "\(dir.path)/stderr" >&2; else cut -d' ' -f2- "\(dir.path)/answer" >&2; fi
        exit "$code"
        """.write(toFile: wrapper, atomically: true, encoding: .utf8)
        if let stderr { try stderr.write(toFile: dir.appendingPathComponent("stderr").path, atomically: true, encoding: .utf8) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper)
        try status.write(toFile: dir.appendingPathComponent("answer").path, atomically: true, encoding: .utf8)
        try stdout.write(toFile: dir.appendingPathComponent("stdout").path, atomically: true, encoding: .utf8)
        return wrapper
    }

    private func openedBackend(answering status: String, stdout: String = "", stderr: String? = nil, delay: Int = 0) async throws -> SystemSSHBackend {
        let backend = SystemSSHBackend(
            environment: ["PATH": "/usr/bin:/bin", "HOME": "/tmp/example-home", "USER": "user", "LOGNAME": "user"],
            resolver: HostAgreeingResolver(),
            client: SSHClientSettings(authMode: .wrapper, wrapperPath: try answeringWrapper(status: status, stdout: stdout, stderr: stderr, delay: delay)),
            loginPath: LoginPath(shell: "/bin/sh", timeout: .seconds(5))
        )
        addTeardownBlock { await backend.close() }
        _ = try await backend.open(try SSHTunnelConfig(alias: "lab.invalid", hostname: "example.invalid", user: "user", sshPort: 2200, refuseTestHost: true))
        return backend
    }

    private let tunnel = try! SSHTunnelConfig(alias: "lab.invalid", hostname: "example.invalid", user: "user", sshPort: 2200, refuseTestHost: true)

    func testExit127IsNamedToolNotFound() async throws {
        let backend = try await openedBackend(answering: "127 sh: 1: hermes: not found\n")
        do {
            _ = try await backend.readProfileList(tunnel)
            XCTFail("readProfileList a réussi avec le code 127")
        } catch let failure as SSHFailure {
            XCTAssertEqual(failure, .remoteToolNotFound)
            XCTAssertFalse(failure.retries)
            XCTAssertTrue(failure.message.contains("introuvable sur l'hôte"), failure.message)
            XCTAssertFalse(failure.message.contains("ne répond pas"), failure.message)
        }
        do {
            _ = try await backend.readAPIKey(tunnel, profile: "cyber")
            XCTFail("readAPIKey a réussi avec le code 127")
        } catch let failure as SSHFailure {
            XCTAssertEqual(failure, .remoteToolNotFound)
        }
        XCTAssertEqual(SSHFailure.remoteToolNotFound.message, "Outil introuvable sur l'hôte : la commande hermes n'est pas dans le PATH du shell de connexion. Ajoute son dossier au profil de connexion de l'hôte, puis réessaie.")
    }

    func testAnotherRemoteExitCodeKeepsItsOwnFailure() async throws {
        let backend = try await openedBackend(answering: "3 Traceback: profil illisible\n")
        do {
            _ = try await backend.readProfileList(tunnel)
            XCTFail("readProfileList a réussi avec le code 3")
        } catch let failure as RemoteCommandFailure {
            XCTAssertEqual(failure, RemoteCommandFailure(status: 3, detail: "Traceback: profil illisible"))
        }
        do {
            _ = try await backend.readAPIKey(tunnel, profile: "cyber")
            XCTFail("readAPIKey a avalé le code 3")
        } catch let failure as APIKeyReadFailure {
            XCTAssertEqual(failure, .commandFailed(status: 3, detail: "Traceback: profil illisible"))
        }
    }

    func testTheBackendReturnsOnlyWhatFollowsTheLoginProfileOutput() async throws {
        let backend = try await openedBackend(answering: "0 \n", stdout: "Welcome\nHERMED_BOTS_REPLY\nprofile-key-VALUE\nrest\n")
        let key = try await backend.readAPIKey(tunnel, profile: "cyber")
        XCTAssertEqual(key, "profile-key-VALUE")
        let list = try await backend.readProfileList(tunnel)
        XCTAssertEqual(list, "profile-key-VALUE\nrest\n")
    }

    /// Hermes 0.22.2 (relevé sur l'instance de test) : la valeur seule sur stdout, les diagnostics des sources de secrets sur stderr
    private let fakeHermesWithInjectedSecrets = #"""
    if [ -s "$HOME/.injected" ]; then
      echo "  Command helper: applied 1 secret" >&2
      cat "$HOME/.injected"
    else
      echo "[secrets:command] helper failed; resolving no value: code=1 signal=none" >&2
      echo "  Command helper: helper command failed (see structured fields above); no secrets applied" >&2
      echo "Config key not set: API_SERVER_KEY" >&2
      exit 1
    fi
    """#

    /// La config du profil n'a pas la clé ; la source de secrets l'injecte au démarrage de la commande, comme pour la gateway
    func testApiKeyIsReadFromInjectedSecretsWhenConfigHasNone() async throws {
        let secret = "injected-profile-key-VALUE"
        let home = try homeWithTool("hermes", body: fakeHermesWithInjectedSecrets)
        try secret.write(toFile: home + "/.injected", atomically: true, encoding: .utf8)
        let key = try config().apiKeyArguments(profile: "cyber").last!
        for outer in outerShells {
            let read = try await replay(key, outer: outer, home: home)
            XCTAssertEqual(read.status, 0, outer)
            // la ligne de diagnostic de la source est sur stderr : elle ne devient pas la clé
            XCTAssertTrue(read.stderr.contains("applied 1 secret"), outer)
            XCTAssertEqual(HermesAPIKey.parse(RemoteShell.reply(read.stdout)), secret, outer)
        }
        // sans injection, la même commande échoue : stderr nomme la cause et la clé reste absente
        try FileManager.default.removeItem(atPath: home + "/.injected")
        let missing = try await replay(key, outer: "/bin/sh", home: home)
        XCTAssertEqual(missing.status, 1)
        XCTAssertTrue(missing.stderr.contains("Config key not set"))
    }

    func testAKeyNotSetReplyCarriesTheSourceDiagnostics() async throws {
        let stderr = """
        [secrets:command] helper failed; resolving no value: code=1 signal=none
          Command helper: helper command failed (see structured fields above); no secrets applied
        Config key not set: API_SERVER_KEY

        """
        let backend = try await openedBackend(answering: "1 ", stderr: stderr)
        do {
            _ = try await backend.readAPIKey(tunnel, profile: "cyber")
            XCTFail("readAPIKey a rendu nil au lieu de nommer la cause")
        } catch let failure as APIKeyReadFailure {
            guard case .keyNotSet(let detail) = failure else { return XCTFail("\(failure)") }
            XCTAssertTrue(detail.contains("helper failed"), detail)
            XCTAssertTrue(detail.contains("no secrets applied"), detail)
            // la dernière ligne ne fait que répéter le diagnostic
            XCTAssertFalse(detail.contains("Config key not set"), detail)
            let message = failure.message(profile: "cyber", holdsKey: false)
            XCTAssertTrue(message.contains("profil cyber"), message)
            XCTAssertTrue(message.contains("source de secrets"), message)
            XCTAssertTrue(message.contains("no secrets applied"), message)
        }
        // sans diagnostic de source, la cause reste nommée
        let bare = try await openedBackend(answering: "1 ", stderr: "Config key not set: API_SERVER_KEY\n")
        do {
            _ = try await bare.readAPIKey(tunnel, profile: "cyber")
            XCTFail("readAPIKey a rendu nil")
        } catch let failure as APIKeyReadFailure {
            XCTAssertEqual(failure, .keyNotSet(detail: ""))
        }
        // un code 0 sans sortie reste « introuvable » : aucune cause à nommer
        let empty = try await openedBackend(answering: "0 ", stdout: "HERMED_BOTS_REPLY\n")
        let none = try await empty.readAPIKey(tunnel, profile: "cyber")
        XCTAssertNil(none)
    }

    func testAKeyReadFailureNamesTheHeldKeyThatHermesRefuses() {
        let failure = APIKeyReadFailure.keyNotSet(detail: "Command helper: no secrets applied")
        let held = failure.message(profile: "cyber", holdsKey: true)
        XCTAssertTrue(held.contains("clé API est refusée pour le profil cyber"), held)
        XCTAssertTrue(held.contains("no secrets applied"), held)
        XCTAssertFalse(failure.message(profile: "cyber", holdsKey: false).contains("refusée"))
    }

    /// Ce que le processus écrit sur stdout et stderr (`print`, `NSLog`) pendant `body`
    private func capturedStandardStreams(_ body: () async throws -> Void) async rethrows -> String {
        fflush(stdout)
        fflush(stderr)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hb-capture-\(UUID().uuidString.prefix(8))")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let capture = open(file.path, O_CREAT | O_RDWR, 0o600)
        let savedOut = dup(STDOUT_FILENO)
        let savedErr = dup(STDERR_FILENO)
        dup2(capture, STDOUT_FILENO)
        dup2(capture, STDERR_FILENO)
        func restore() {
            fflush(stdout)
            fflush(stderr)
            dup2(savedOut, STDOUT_FILENO)
            dup2(savedErr, STDERR_FILENO)
            close(savedOut)
            close(savedErr)
            close(capture)
        }
        do { try await body() } catch { restore(); throw error }
        restore()
        return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    /// La valeur de la clé ne sort jamais de la lecture que vers l'appelant : ni message, ni description, ni sortie du processus
    func testApiKeyValueNeverReachesLogs() async throws {
        let secret = "leaky-key-VALUE-0123456789abcdefghij"
        let stderr = """
        API_SERVER_KEY=\(secret)
        authorization: Bearer \(secret)
        source failed for token \(secret)
        Config key not set: API_SERVER_KEY

        """
        let backend = try await openedBackend(answering: "1 ", stderr: stderr)
        let ok = try await openedBackend(answering: "0 ", stdout: "HERMED_BOTS_REPLY\n\(secret)\n")
        var surfaces: [String] = []
        var read: String?
        let streams = await capturedStandardStreams {
            do {
                _ = try await backend.readAPIKey(tunnel, profile: "cyber")
                XCTFail("readAPIKey a réussi")
            } catch {
                guard let failure = error as? APIKeyReadFailure else { return XCTFail("\(error)") }
                surfaces = [
                    failure.message(profile: "cyber", holdsKey: false), failure.message(profile: "cyber", holdsKey: true),
                    "\(failure)", String(describing: failure), String(reflecting: failure), (failure as NSError).localizedDescription,
                ]
                var dumped = ""
                dump(failure, to: &dumped)
                surfaces.append(dumped)
            }
            // la lecture qui réussit rend la valeur à l'appelant seulement
            read = try? await ok.readAPIKey(tunnel, profile: "cyber")
        }
        XCTAssertEqual(read, secret)
        XCTAssertEqual(surfaces.count, 7)
        for surface in surfaces { XCTAssertFalse(surface.contains(secret), surface) }
        // le masque garde le nom de la variable et la cause, pas la valeur
        XCTAssertTrue(surfaces.first?.contains("API_SERVER_KEY") == true, surfaces.first ?? "")
        XCTAssertFalse(streams.contains(secret), "la valeur a été écrite sur stdout ou stderr")
    }

    func testDiagnosticMaskingKeepsTheCauseAndDropsTheValues() {
        let masked = RemoteShell.diagnostic(of: """
        OPENAI_API_KEY=sk-live-0123456789abcdef0123456789
        helper failed token=short client_secret: abcdef
        un jeton sans nom 0123456789abcdefghijklmnopqrstuv fin
        """)
        for value in ["sk-live-0123456789abcdef0123456789", "abcdef", "short", "0123456789abcdefghijklmnopqrstuv"] {
            XCTAssertFalse(masked.contains(value), masked)
        }
        XCTAssertTrue(masked.contains("OPENAI_API_KEY"), masked)
        XCTAssertTrue(masked.contains("helper failed"), masked)
        // un chemin et un mot courant gardent leur forme
        XCTAssertEqual(RemoteShell.diagnostic(of: "PermissionError: /srv/hermes/profiles/cyber/.env illisible"), "PermissionError: /srv/hermes/profiles/cyber/.env illisible")
        // trois lignes au plus, 400 caractères au plus, sans caractère de contrôle
        let long = RemoteShell.diagnostic(of: (1...10).map { "ligne \($0) " + String(repeating: "x", count: 20) }.joined(separator: "\n") + "\u{1b}[31m")
        XCTAssertLessThanOrEqual(long.split(separator: "\n").count, 3)
        XCTAssertFalse(long.contains("\u{1b}"))
        XCTAssertLessThanOrEqual(RemoteShell.diagnostic(of: String(repeating: "mot ", count: 500)).count, 400)
    }

    @MainActor
    func testAKeyReadFailureWithAReasonIsRememberedByTheKeyReadGuard() async throws {
        var store = InMemorySecretStore(apiKey: nil)
        let fetches = APIKeyFetches()
        var reads = 0
        func read(_ name: String) async throws -> String? {
            reads += 1
            throw APIKeyReadFailure.keyNotSet(detail: "Command helper: no secrets applied")
        }
        for attempt in 1...2 {
            do {
                _ = try await fetches.fetch(profile: "cyber", into: &store, read: read)
                XCTFail("la cause a été avalée à l'essai \(attempt)")
            } catch let failure as APIKeyReadFailure {
                XCTAssertEqual(failure, .keyNotSet(detail: "Command helper: no secrets applied"))
            }
        }
        XCTAssertEqual(reads, 1)
        // un autre profil lit pour lui-même ; un nouvel essai explicite relit
        _ = try? await fetches.fetch(profile: "sport", into: &store, read: read)
        XCTAssertEqual(reads, 2)
        fetches.reset()
        _ = try? await fetches.fetch(profile: "cyber", into: &store, read: read)
        XCTAssertEqual(reads, 3)
    }

    // MARK: sonde Desktop

    /// Réponses de la sonde pour reconnaître l'interpréteur qui l'a lancée
    private let viaHermes = #"{"held": ["via-hermes"]}"#
    private let viaSystem = #"{"held": ["via-system"]}"#

    private func writeScript(_ path: String, _ body: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    private enum HermesLayout {
        /// `hermes` est un script dont la ligne #! nomme `venv/bin/python` (nil) ou une autre ligne
        case shebang(String?)
        /// Comme Hermes 0.22.2 : `.local/bin/hermes` mène par deux liens relatifs à `racine/libexec/hermes`, l'interpréteur est `racine/.venv/bin/python`
        case launcher
    }

    /// Un HOME où `python3` du PATH de connexion répond `viaSystem`, et où l'interpréteur de Hermes répond `viaHermes` en notant ses arguments
    private func homeWithProbeInterpreters(layout: HermesLayout = .shebang(nil), venvBody: String? = nil, banner: String? = nil) throws -> String {
        let home = try homeWithTool("python3", body: "echo '\(viaSystem)'", banner: banner)
        let body = "#!/bin/sh\n" + (venvBody ?? "printf '%s\\n' \"$@\" > \"$HOME/venv-args\"\necho '\(viaHermes)'") + "\n"
        switch layout {
        case .shebang(let line):
            let venv = home + "/venv/bin/python"
            try writeScript(venv, body)
            try writeScript(home + "/.local/bin/hermes", "\(line ?? "#!" + venv)\nprint('hermes')\n")
        case .launcher:
            let root = home + "/hermes-root"
            try writeScript(root + "/.venv/bin/python", body)
            try writeScript(root + "/libexec/hermes", "#!/usr/bin/env bash\nexit 0\n")
            try FileManager.default.createDirectory(atPath: root + "/bin", withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: root + "/bin/hermes", withDestinationPath: "../libexec/hermes")
            try FileManager.default.createSymbolicLink(atPath: home + "/.local/bin/hermes", withDestinationPath: "../../hermes-root/bin/hermes")
        }
        return home
    }

    func testProbeRunsWithHermesInterpreter() async throws {
        for layout in [HermesLayout.shebang(nil), .launcher] {
            let home = try homeWithProbeInterpreters(layout: layout)
            for outer in outerShells {
                let output = try await replay(ProfileLock.command, outer: outer, home: home)
                XCTAssertEqual(output.status, 0, "\(layout) \(outer) \(output.stderr)")
                XCTAssertEqual(RemoteShell.reply(output.stdout), viaHermes + "\n", "\(layout) \(outer)")
            }
            // l'interpréteur reçoit la sonde elle-même, en `-c`
            let args = try String(contentsOfFile: home + "/venv-args", encoding: .utf8)
            XCTAssertEqual(args, "-c\n" + ProfileLock.probe + "\n", "\(layout)")
        }
        // et la commande envoyée à ssh n'est que le lanceur : le PATH de connexion s'applique
        XCTAssertTrue(ProfileLock.command.hasPrefix("sh -lc "), ProfileLock.command)
    }

    func testProbeFallsBackToSystemPython() async throws {
        let cases: [(String, String?, String?)] = [
            ("ligne #! en env", "#!/usr/bin/env python3", nil),
            ("interpréteur absent", "#!/nonexistent/venv/bin/python", nil),
            ("interpréteur sans psutil", nil, "echo 'module psutil absent' >&2\nexit 3"),
        ]
        for (label, line, venvBody) in cases {
            let home = try homeWithProbeInterpreters(layout: .shebang(line), venvBody: venvBody)
            for outer in outerShells {
                let output = try await replay(ProfileLock.command, outer: outer, home: home)
                XCTAssertEqual(output.status, 0, "\(label) \(outer) \(output.stderr)")
                XCTAssertEqual(RemoteShell.reply(output.stdout), viaSystem + "\n", "\(label) \(outer)")
            }
        }
        // un lanceur dont l'interpréteur n'a pas psutil : repli sur python3
        let launcherWithoutModule = try homeWithProbeInterpreters(layout: .launcher, venvBody: "echo 'module psutil absent' >&2\nexit 3")
        let fallback = try await replay(ProfileLock.command, outer: "/bin/sh", home: launcherWithoutModule)
        XCTAssertEqual(RemoteShell.reply(fallback.stdout), viaSystem + "\n")
        // aucun hermes dans le PATH
        let bare = try homeWithTool("python3", body: "echo '\(viaSystem)'")
        let output = try await replay(ProfileLock.command, outer: "/bin/sh", home: bare)
        XCTAssertEqual(RemoteShell.reply(output.stdout), viaSystem + "\n")
        // une erreur de l'interpréteur de Hermes autre que le module manquant n'est pas masquée par le repli
        let broken = try homeWithProbeInterpreters(venvBody: "echo 'ValueError: profil illisible' >&2\nexit 1")
        let failed = try await replay(ProfileLock.command, outer: "/bin/sh", home: broken)
        XCTAssertEqual(failed.status, 1)
        XCTAssertTrue(failed.stderr.contains("profil illisible"), failed.stderr)
    }

    func testTheProbeSourceExitsWithTheDedicatedStatusWhenPsutilIsMissing() async throws {
        // `sys.modules["psutil"] = None` fait échouer l'import comme un module absent
        let blocked = try await Spawn.run(
            "/usr/bin/python3",
            ["-c", "import sys; sys.modules['psutil'] = None; exec(sys.argv[1])", ProfileLock.probe],
            environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"], timeout: .seconds(10)
        )
        XCTAssertEqual(blocked.status, ProfileLock.moduleMissingStatus)
        XCTAssertTrue(blocked.stderr.contains("psutil"), blocked.stderr)
        XCTAssertEqual(blocked.stdout, "")
    }

    func testTheProbeAnswersThroughAChattyLoginProfile() async throws {
        let home = try homeWithProbeInterpreters(banner: "Welcome to the host")
        let output = try await replay(ProfileLock.command, outer: "/bin/sh", home: home)
        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertEqual(RemoteShell.reply(output.stdout), viaHermes + "\n")
        XCTAssertTrue(output.stdout.contains("Welcome to the host"))
    }

    func testTheBackendNamesEachProbeFailure() async throws {
        let cases: [(status: String, stderr: String?, expected: ProfileProbeFailure)] = [
            ("3 ", "module psutil absent\n", .moduleMissing("psutil")),
            ("127 ", "sh: python3: not found\n", .toolNotFound),
            ("1 ", "Traceback (most recent call last):\n  File \"<string>\", line 4\nValueError: boom\n", .failed(status: 1, detail: "Traceback (most recent call last):\nFile \"<string>\", line 4\nValueError: boom")),
        ]
        for (status, stderr, expected) in cases {
            let backend = try await openedBackend(answering: status, stderr: stderr)
            do {
                _ = try await backend.readProfileLocks(tunnel)
                XCTFail("readProfileLocks a réussi avec \(status)")
            } catch let failure as ProfileProbeFailure {
                XCTAssertEqual(failure, expected)
            }
        }
        // ssh lui-même refuse : la cause de ssh, pas celle de la sonde
        let refused = try await openedBackend(answering: "255 ", stderr: "user@example.invalid: Permission denied (publickey).\n")
        do {
            _ = try await refused.readProfileLocks(tunnel)
            XCTFail("readProfileLocks a réussi avec 255")
        } catch let failure as SSHFailure {
            XCTAssertEqual(failure, .wrongKey(""))
        }
        // la réponse n'est que ce qui suit le marqueur de connexion
        let ok = try await openedBackend(answering: "0 ", stdout: "Welcome\nHERMED_BOTS_REPLY\n{\"held\": []}\n")
        let data = try await ok.readProfileLocks(tunnel)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"held\": []}\n")
    }

    func testAProbeThatTimesOutIsNamed() async throws {
        let slow = try await openedBackend(answering: "0 ", stdout: "HERMED_BOTS_REPLY\n{\"held\": []}\n", delay: 3)
        do {
            _ = try await slow.readProfileLocks(tunnel, timeout: .milliseconds(500))
            XCTFail("la sonde lente a répondu")
        } catch let failure as ProfileProbeFailure {
            XCTAssertEqual(failure, .timedOut)
        }
    }

    /// La bannière dit pourquoi la détection de Desktop est indisponible, au lieu de « indisponible » seul
    @MainActor
    func testProbeFailureShowsItsReason() async {
        var failure: Error = ProfileProbeFailure.moduleMissing("psutil")
        var answering = false
        let lock = ProfileLock(connection: { "host-a" }, read: {
            if answering { return Data(#"{"held": ["hv-bot-b"]}"#.utf8) }
            throw failure
        })
        // avant toute lecture : l'état est inconnu, sans cause à dire
        XCTAssertEqual(lock.state("hv-bot-a"), .unknown)
        XCTAssertEqual(lock.reason("hv-bot-a"), ProfileLock.State.unknown.reason)

        for (error, expected) in [
            (ProfileProbeFailure.moduleMissing("psutil") as Error, "psutil"),
            (ProfileProbeFailure.toolNotFound, "introuvable"),
            (ProfileProbeFailure.failed(status: 1, detail: "ValueError: boom"), "ValueError: boom"),
            (ProfileProbeFailure.timedOut, "n'a pas répondu"),
            (SSHFailure.unreachable("Connection refused"), "Connection refused"),
        ] {
            failure = error
            let read = await lock.refresh()
            XCTAssertFalse(read)
            XCTAssertEqual(lock.state("hv-bot-a"), .unknown)
            let reason = lock.reason("hv-bot-a") ?? ""
            XCTAssertTrue(reason.hasPrefix(ProfileLock.State.unknown.reason ?? "?"), reason)
            XCTAssertTrue(reason.contains(expected), "\(expected) absent de : \(reason)")
        }
        // une panne sans cause nommée garde le message d'origine
        failure = CocoaError(.fileReadUnknown)
        _ = await lock.refresh()
        XCTAssertEqual(lock.reason("hv-bot-a"), ProfileLock.State.unknown.reason)
        // un tunnel fermé a sa propre bannière : il n'est pas une cause de la sonde
        failure = SSHFailure.tunnelClosed
        _ = await lock.refresh()
        XCTAssertEqual(lock.reason("hv-bot-a"), ProfileLock.State.unknown.reason)

        // la sonde répond : la cause disparaît avec l'état inconnu
        answering = true
        let read = await lock.refresh()
        XCTAssertTrue(read)
        XCTAssertNil(lock.reason("hv-bot-a"))
        XCTAssertEqual(lock.reason("hv-bot-b"), ProfileLock.State.held.reason)
        // une panne suivante nomme sa propre cause, pas celle d'avant
        answering = false
        failure = ProfileProbeFailure.timedOut
        _ = await lock.refresh()
        let latest = lock.reason("hv-bot-a") ?? ""
        XCTAssertTrue(latest.contains("n'a pas répondu"), latest)
        XCTAssertFalse(latest.contains("CocoaError"), latest)
    }

    /// La cause d'un hôte ne s'affiche pas pour un autre
    @MainActor
    func testTheProbeFailureReasonBelongsToItsHost() async {
        var host = "host-a"
        var broken = true
        let lock = ProfileLock(connection: { host }, read: {
            if broken { throw ProfileProbeFailure.moduleMissing("psutil") }
            return Data(#"{"held": []}"#.utf8)
        })
        _ = await lock.refresh()
        XCTAssertTrue(lock.reason("hv-bot-a")?.contains("psutil") == true)
        host = "host-b"
        broken = false
        XCTAssertEqual(lock.reason("hv-bot-a"), ProfileLock.State.unknown.reason)
        _ = await lock.refresh()
        XCTAssertNil(lock.reason("hv-bot-a"))
        host = "host-a"
        XCTAssertTrue(lock.reason("hv-bot-a")?.contains("psutil") == true, "l'hôte A garde sa propre cause")
    }

    @MainActor
    func testAMissingToolIsNotSwallowedByTheKeyReadGuard() async throws {
        var store = InMemorySecretStore(apiKey: nil)
        let fetches = APIKeyFetches()
        var reads = 0
        func read(_ name: String) async throws -> String? {
            reads += 1
            throw SSHFailure.remoteToolNotFound
        }
        do {
            _ = try await fetches.fetch(profile: "cyber", into: &store, read: read)
            XCTFail("127 a été avalé")
        } catch let failure as SSHFailure {
            XCTAssertEqual(failure, .remoteToolNotFound)
        }
        // le même refus ne relit pas, et ne rend pas non plus nil (« clé introuvable ») : l'outil manque toujours
        do {
            _ = try await fetches.fetch(profile: "cyber", into: &store, read: read)
            XCTFail("la garde a rendu nil au lieu de nommer l'outil")
        } catch let failure as SSHFailure {
            XCTAssertEqual(failure, .remoteToolNotFound)
        }
        XCTAssertEqual(reads, 1)
        // une autre panne reste silencieuse : la bannière « refusée » ou « introuvable » la dit déjà
        let other = APIKeyFetches()
        let silent = try await other.fetch(profile: "cyber", into: &store) { _ in throw SSHFailure.unreachable("coupure") }
        XCTAssertNil(silent)
        // un nouvel essai explicite relit
        fetches.reset()
        do {
            _ = try await fetches.fetch(profile: "cyber", into: &store, read: read)
            XCTFail("127 a été avalé après reset")
        } catch is SSHFailure {}
        XCTAssertEqual(reads, 2)
    }

    @MainActor
    func testAToolNotFoundStopsTheAutomaticProfileReadsUntilAnExplicitRetry() async throws {
        var reads = 0
        var toolPresent = false
        let bots = BotsModel(
            interval: .milliseconds(10),
            readProfiles: {
                reads += 1
                if !toolPresent { throw SSHFailure.remoteToolNotFound }
                return []
            },
            client: { nil },
            connection: { "lab.invalid" }
        )
        let loop = Task { await bots.run() }
        addTeardownBlock { loop.cancel() }
        try await Task.sleep(for: .milliseconds(200))
        // sans l'arrêt, une lecture ssh partirait à chaque intervalle
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(bots.phase, .toolNotFound(SSHFailure.remoteToolNotFound.message))
        // « Réessayer » relit une fois, toujours sans l'outil
        await bots.refresh()
        XCTAssertEqual(reads, 2)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reads, 2)
        // l'outil est là : la relecture explicite réussit et la boucle reprend
        toolPresent = true
        await bots.refresh()
        XCTAssertEqual(bots.phase, .ready)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertGreaterThan(reads, 3)
    }

    @MainActor
    func testAToolNotFoundAfterASuccessfulListStopsTheAutomaticReads() async throws {
        var reads = 0
        var toolPresent = true
        let bots = BotsModel(
            interval: .milliseconds(10),
            readProfiles: {
                reads += 1
                if !toolPresent { throw SSHFailure.remoteToolNotFound }
                return []
            },
            client: { nil },
            connection: { "lab.invalid" }
        )
        await bots.refresh()
        XCTAssertEqual(bots.phase, .ready)
        // la liste lue reste affichée quand l'outil disparaît ensuite
        toolPresent = false
        let loop = Task { await bots.run() }
        addTeardownBlock { loop.cancel() }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(bots.phase, .ready)
        // la première lecture de la boucle voit le 127 ; sans l'arrêt, une lecture ssh partirait à chaque intervalle
        XCTAssertEqual(reads, 2)
        // « Réessayer » relit une fois, puis la boucle reste arrêtée
        await bots.refresh()
        XCTAssertEqual(reads, 3)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reads, 3)
        // l'outil revient : la relecture explicite réussit et la boucle reprend
        toolPresent = true
        await bots.refresh()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertGreaterThan(reads, 5)
    }

    @MainActor
    func testAToolNotFoundOnTheHostIsNotReportedAsAnUnresponsiveHermes() async {
        let bots = BotsModel(readProfiles: { throw SSHFailure.remoteToolNotFound }, client: { nil }, connection: { "lab.invalid" })
        await bots.refresh()
        XCTAssertEqual(bots.phase, .toolNotFound(SSHFailure.remoteToolNotFound.message))
        let other = BotsModel(readProfiles: { throw RemoteCommandFailure(status: 1, detail: "x") }, client: { nil }, connection: { "lab.invalid" })
        await other.refresh()
        XCTAssertEqual(other.phase, .failed("La commande « hermes profile list » a échoué (code 1) : x"))
    }
}

/// `ssh -G` d'un alias qui reste sur la route du tunnel de ces tests
private struct HostAgreeingResolver: SSHConfigResolving {
    private let dump = SSHConfigDump(stdout: "hostname example.invalid\nuser user\nport 2200\n")

    func dump(alias: String, invocation: SSHInvocation, agentSocket: String?) async throws -> SSHConfigDump { dump }

    func dumpAPIKey(alias: String, profile: String, agentSocket: String?) async throws -> SSHConfigDump { dump }
}

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
