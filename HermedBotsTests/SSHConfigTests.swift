import XCTest

final class SSHConfigTests: XCTestCase {
    private let localUser = "operator"

    /// Sortie aplatie de `ssh -G` après un `Include` : l'alias `lab` pointe vers un hôte `.invalid`
    private let includedDump = """
        user operator
        hostname gateway.invalid
        port 2222
        identityagent /tmp/fake-agent.invalid
        identityfile /tmp/fake-id.invalid
        certificatefile /tmp/fake-id.invalid-cert.pub
        proxyjump none
        proxycommand none
        """

    /// Sortie de `ssh -G` pour un nom sans bloc Host : l'alias est renvoyé tel quel, port 22, identités par défaut
    private let defaultDump = """
        user operator
        hostname unknown-alias.invalid
        port 22
        identityfile ~/.ssh/id_rsa
        identityfile ~/.ssh/id_ecdsa
        identityfile ~/.ssh/id_ecdsa_sk
        identityfile ~/.ssh/id_ed25519
        identityfile ~/.ssh/id_ed25519_sk
        identityfile ~/.ssh/id_xmss
        identityfile ~/.ssh/id_dsa
        proxyjump none
        proxycommand none
        """

    private let unmatchedDebug = "debug1: Reading configuration data\ndebug1: Applying options for *\n"
    private func matchedDebug(_ alias: String) -> String {
        "debug1: Applying options for \(alias)\ndebug1: Applying options for *\n"
    }

    private func parse(_ dump: String, alias: String, debug: String = "", existing: Set<String> = [], authSock: String? = nil) -> SSHConnectionPreview {
        SSHConfig.parse(
            dump,
            debug: debug,
            alias: alias,
            localUser: localUser,
            filesExist: { existing.contains($0) },
            authSock: authSock
        )
    }

    func testAnIncludedHostBlockResolvesEveryFieldWithoutSecrets() {
        let preview = parse(includedDump, alias: "lab", debug: matchedDebug("lab"), existing: ["/tmp/fake-id.invalid-cert.pub"])
        XCTAssertFalse(preview.isUnknownAlias)
        XCTAssertEqual(preview.hostname, "gateway.invalid")
        XCTAssertEqual(preview.user, "operator")
        XCTAssertEqual(preview.port, 2222)
        XCTAssertFalse(preview.hasRelay)
        XCTAssertEqual(preview.identity, .certificate)
        XCTAssertEqual(preview.identity.label, "certificat")
        XCTAssertTrue(preview.identityPresent)
        XCTAssertEqual(preview.identityPresentTitle, "Certificat")
        XCTAssertEqual(preview.identityPresentLabel, "présent")
        XCTAssertFalse(preview.hostname.contains("BEGIN"))
        XCTAssertFalse(preview.identityPresentLabel.contains("/tmp"))
        XCTAssertFalse(preview.identity.label.contains("/tmp"))
    }

    func testAnUnknownAliasIsTheNameAsTypedOnPort22WithOnlyDefaultIdentities() {
        let preview = parse(defaultDump, alias: "unknown-alias.invalid", debug: unmatchedDebug)
        XCTAssertTrue(preview.isUnknownAlias)
        XCTAssertEqual(preview.hostname, "unknown-alias.invalid")
        XCTAssertEqual(preview.port, 22)
        XCTAssertFalse(preview.hasRelay)
        XCTAssertEqual(preview.identity, .file)
        XCTAssertFalse(preview.identityPresent)
        XCTAssertThrowsError(try SSHConnectionPlanner.config(from: preview, refusePersoHermes: true)) {
            XCTAssertEqual($0 as? SSHFailure, .unknownAlias)
        }
    }

    func testAValidAliasWithOnlyStandardValuesIsNotUnknown() {
        let dump = defaultDump.replacingOccurrences(of: "unknown-alias.invalid", with: "lab.invalid")
        let preview = parse(dump, alias: "lab.invalid", debug: matchedDebug("lab.invalid"))
        XCTAssertFalse(preview.isUnknownAlias)
        XCTAssertEqual(preview.hostname, "lab.invalid")
        XCTAssertEqual(preview.port, 22)
        XCTAssertNoThrow(try SSHConnectionPlanner.config(from: preview, refusePersoHermes: true))
    }

    func testAMatchingBlockWithTheSameNameIsStillKnownWhenUserOrIdentityDiffer() {
        let dump = """
            user hermes
            hostname lab.invalid
            port 22
            identityfile /tmp/fake-id.invalid
            identityfile ~/.ssh/id_rsa
            proxyjump none
            """
        let preview = parse(dump, alias: "lab.invalid", debug: matchedDebug("lab.invalid"), existing: ["/tmp/fake-id.invalid.pub"])
        XCTAssertFalse(preview.isUnknownAlias)
        XCTAssertEqual(preview.identity, .file)
        XCTAssertTrue(preview.identityPresent)
        XCTAssertEqual(preview.identityPresentTitle, "Clé publique")
        XCTAssertEqual(preview.identityPresentLabel, "présente")
    }

    func testAnAgentIdentityUsesTheSessionSocketWithoutReadingTheKeychain() {
        let dump = """
            user operator
            hostname gateway.invalid
            port 2200
            identityagent SSH_AUTH_SOCK
            identityfile ~/.ssh/id_ed25519
            proxyjump none
            """
        let preview = parse(dump, alias: "lab", existing: ["/tmp/example-agent.invalid"], authSock: "/tmp/example-agent.invalid")
        XCTAssertEqual(preview.identity, .agent)
        XCTAssertTrue(preview.identityPresent)
        XCTAssertEqual(preview.identity.label, "agent SSH")
    }

    func testReadonlyLabelsNeverIncludeAPathOrAKey() {
        let preview = parse(includedDump, alias: "lab")
        for text in [preview.user, preview.hostname, preview.identity.label, preview.identityPresentLabel, preview.identityPresentTitle] {
            XCTAssertFalse(text.contains("PRIVATE"))
            XCTAssertFalse(text.contains("BEGIN"))
            XCTAssertFalse(text.contains("Trousseau"))
        }
        XCTAssertEqual(preview.user, "operator")
    }

    func testTheResolvedPersoHermesHostIsRefusedInTestMode() {
        let dump = """
            user operator
            hostname perso-hermes.invalid
            port 22
            identityfile /tmp/fake-id.invalid
            """
        let preview = parse(dump, alias: "lab.invalid", debug: matchedDebug("lab.invalid"))
        XCTAssertFalse(preview.isUnknownAlias)
        XCTAssertThrowsError(try SSHConnectionPlanner.config(from: preview, refusePersoHermes: true)) {
            XCTAssertEqual($0 as? SSHFailure, .forbiddenHost)
        }
        XCTAssertNoThrow(try SSHConnectionPlanner.config(from: preview, refusePersoHermes: false))
    }

    func testPersoHermesIsRefusedBeforeAnUnknownAliasCheck() {
        let dump = defaultDump.replacingOccurrences(of: "unknown-alias.invalid", with: "perso-hermes.invalid")
        let preview = parse(dump, alias: "perso-hermes.invalid", debug: unmatchedDebug)
        XCTAssertTrue(preview.isUnknownAlias)
        XCTAssertThrowsError(try SSHConnectionPlanner.config(from: preview, refusePersoHermes: true)) {
            XCTAssertEqual($0 as? SSHFailure, .forbiddenHost)
        }
    }

    /// `ssh -G -vv -F /dev/null nom` n'écrit aucune ligne « Applying options for » : aucun bloc ne couvre l'alias
    func testAnAliasWithNoApplyingOptionsLineAtAllIsUnknown() {
        let noBlockDebug = "debug1: Reading configuration data /dev/null\n"
        for debug in [noBlockDebug, ""] {
            let preview = parse(defaultDump, alias: "unknown-alias.invalid", debug: debug)
            XCTAssertTrue(preview.isUnknownAlias, debug)
            XCTAssertThrowsError(try SSHConnectionPlanner.config(from: preview, refusePersoHermes: true)) {
                XCTAssertEqual($0 as? SSHFailure, .unknownAlias)
            }
        }
    }

    /// `Host *` qui fixe des valeurs ne fait pas d'un nom quelconque un alias : seul un bloc Host ou Match qui nomme l'alias le rend connu
    func testAnAliasWithNoBlockOfItsOwnIsUnknownWhateverHostStarSets() {
        let dumps = [
            "user otheroperator": defaultDump.replacingOccurrences(of: "user operator", with: "user otheroperator"),
            "port 2222": defaultDump.replacingOccurrences(of: "port 22", with: "port 2222"),
            "hostname other.invalid": defaultDump.replacingOccurrences(of: "unknown-alias.invalid", with: "other.invalid"),
            "identityfile": "identityfile /tmp/fake-id.invalid\n" + defaultDump,
            "identityagent": defaultDump + "\nidentityagent /tmp/fake-agent.invalid",
            "certificatefile": defaultDump + "\ncertificatefile /tmp/fake-id.invalid-cert.pub",
        ]
        for (what, dump) in dumps {
            let unnamed = parse(dump, alias: "unknown-alias.invalid", debug: unmatchedDebug)
            XCTAssertTrue(unnamed.isUnknownAlias, what)
            XCTAssertThrowsError(try SSHConnectionPlanner.config(from: unnamed, refusePersoHermes: true), what) {
                XCTAssertEqual($0 as? SSHFailure, .unknownAlias, what)
            }
            let named = parse(dump, alias: "unknown-alias.invalid", debug: matchedDebug("unknown-alias.invalid"))
            XCTAssertFalse(named.isUnknownAlias, what)
        }
    }

    /// `ssh -G -vv` écrit `originally <alias>` puis `match found` quand un bloc Match couvre l'alias
    func testAMatchBlockThatCoversTheAliasMakesItKnown() {
        let debug = """
            debug1: Reading configuration data /dev/null
            debug2: checking match for 'host lab.invalid' host lab.invalid originally lab.invalid
            debug2: match found
            """
        let preview = parse(defaultDump.replacingOccurrences(of: "user operator", with: "user otheroperator"), alias: "lab.invalid", debug: debug)
        XCTAssertFalse(preview.isUnknownAlias)
    }

    /// `IdentityAgent none` désactive l'agent : la socket de la session ne compte plus, quelle que soit la casse
    func testIdentityAgentNoneUsesNoAgentEvenWithASessionSocket() {
        for value in ["none", "NONE"] {
            let standard = parse(defaultDump + "\nidentityagent \(value)", alias: "lab.invalid", debug: matchedDebug("lab.invalid"), existing: [NSHomeDirectory() + "/.ssh/id_ed25519", "/tmp/example-agent.invalid"], authSock: "/tmp/example-agent.invalid")
            XCTAssertEqual(standard.identity, .file, value)
            XCTAssertNotEqual(standard.identity.label, "agent SSH", value)
            XCTAssertTrue(standard.identityPresent, value)
            let custom = parse("user operator\nhostname lab.invalid\nport 22\nidentityagent \(value)\nidentityfile /tmp/fake-id.invalid", alias: "lab.invalid", debug: matchedDebug("lab.invalid"), existing: ["/tmp/example-agent.invalid"], authSock: "/tmp/example-agent.invalid")
            XCTAssertEqual(custom.identity, .file, value)
            XCTAssertFalse(custom.identityPresent, "\(value) : seule la socket existe, et l'agent est désactivé")
        }
    }

    /// Un alias dont la config résolue contient un ProxyJump ou un ProxyCommand est refusé, quelle que soit la valeur, en mode test comme hors mode test
    func testAnyProxyJumpOrProxyCommandIsRefusedInEveryMode() {
        let relays = [
            "proxyjump bastion.invalid",
            "proxyjump operator@bastion.invalid:2222,second.invalid",
            "proxyjump perso-hermes.invalid",
            "proxyjump -",
            "proxycommand /usr/bin/nc bastion.invalid 22",
            "proxycommand /usr/bin/ssh -W %h:%p perso-hermes.invalid",
            "proxycommand true",
        ]
        for relay in relays {
            let dump = """
                user operator
                hostname gateway.invalid
                port 22
                identityfile /tmp/fake-id.invalid
                \(relay)
                """
            let preview = parse(dump, alias: "lab.invalid", debug: matchedDebug("lab.invalid"))
            XCTAssertTrue(preview.hasRelay, relay)
            for refuse in [true, false] {
                XCTAssertThrowsError(try SSHConnectionPlanner.config(from: preview, refusePersoHermes: refuse), relay) {
                    XCTAssertEqual($0 as? SSHFailure, .relayRefused, relay)
                }
            }
        }
    }

    /// OpenSSH écrit `none` pour supprimer un relais hérité : ce n'est pas un relais
    func testNoneIsNotARelay() {
        let preview = parse(includedDump, alias: "lab", debug: matchedDebug("lab"), existing: ["/tmp/fake-id.invalid-cert.pub"])
        XCTAssertFalse(preview.hasRelay)
        XCTAssertNoThrow(try SSHConnectionPlanner.config(from: preview, refusePersoHermes: false))
    }

    /// Un bloc `Match sessiontype none` ou `Match command` ne s'applique qu'à un lancement : `ssh -G` reçoit les arguments exacts de chaque lancement réel
    func testEachSshInvocationIsResolvedWithTheArgumentsItIsLaunchedWith() throws {
        let config = try SSHTunnelConfig(alias: "lab.invalid", hostname: "gateway.invalid", user: "operator", refusePersoHermes: true)
        let launched: [SSHInvocation: [String]] = [
            .tunnel: config.arguments(localPort: 1),
            .profileList: config.profileListArguments(),
            .profileLocks: config.profileLocksArguments(),
        ]
        XCTAssertEqual(Set(launched.keys), Set(SSHInvocation.allCases))
        for invocation in SSHInvocation.allCases {
            XCTAssertEqual(
                SystemSSHConfigResolver.arguments(alias: "lab.invalid", invocation: invocation),
                ["-G", "-vv"] + launched[invocation]!,
                "\(invocation)"
            )
        }
        XCTAssertTrue(SystemSSHConfigResolver.arguments(alias: "lab.invalid", invocation: .tunnel).contains("-N"))
        XCTAssertFalse(SystemSSHConfigResolver.arguments(alias: "lab.invalid", invocation: .profileList).contains("-N"))
    }

}

@MainActor
final class SSHConnectorTests: XCTestCase {
    private func knownDump(alias: String, hostname: String) -> SSHConfigDump {
        SSHConfigDump(
            stdout: """
            user operator
            hostname \(hostname)
            port 22
            identityfile /tmp/fake-id.invalid
            proxyjump none
            """,
            stderr: "debug1: Applying options for \(alias)\n"
        )
    }

    func testALaterConnectIgnoresAStaleResolution() async {
        let resolver = GatedSSHResolver(dumps: [
            "a.invalid": knownDump(alias: "a.invalid", hostname: "alpha.invalid"),
            "b.invalid": knownDump(alias: "b.invalid", hostname: "beta.invalid"),
        ])
        let connector = SSHConnector(resolver: resolver, localUser: "operator")
        var opened: [String] = []
        var refused: [SSHFailure] = []
        connector.begin(alias: "a.invalid", refusePersoHermes: true, opened: { config, _ in opened.append(config.alias) }, refused: { failure, _ in refused.append(failure) })
        await eventually { await resolver.started == ["a.invalid"] }
        connector.begin(alias: "b.invalid", refusePersoHermes: true, opened: { config, _ in opened.append(config.alias) }, refused: { failure, _ in refused.append(failure) })
        await eventually { await resolver.started == ["a.invalid", "b.invalid"] }
        await resolver.release("b.invalid")
        await eventually { opened == ["b.invalid"] }
        await resolver.release("a.invalid")
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(opened, ["b.invalid"])
        XCTAssertEqual(refused, [])
    }

    func testAnEmptyBeginInvalidatesAnInFlightResolution() async {
        let resolver = GatedSSHResolver(dumps: [
            "a.invalid": knownDump(alias: "a.invalid", hostname: "alpha.invalid"),
        ])
        let connector = SSHConnector(resolver: resolver, localUser: "operator")
        var opened: [String] = []
        var refused: [SSHFailure] = []
        connector.begin(alias: "a.invalid", refusePersoHermes: true, opened: { config, _ in opened.append(config.alias) }, refused: { failure, _ in refused.append(failure) })
        await eventually { await resolver.started == ["a.invalid"] }
        connector.begin(alias: "   ", refusePersoHermes: true, opened: { config, _ in opened.append(config.alias) }, refused: { failure, _ in refused.append(failure) })
        XCTAssertEqual(refused, [.invalidHost])
        let startedAfterEmpty = await resolver.started
        XCTAssertEqual(startedAfterEmpty, ["a.invalid"])
        await resolver.release("a.invalid")
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(opened, [])
        XCTAssertEqual(refused, [.invalidHost])
    }

    func testAnInvalidBeginInvalidatesAnInFlightResolutionWithoutADump() async {
        let resolver = GatedSSHResolver(dumps: [
            "a.invalid": knownDump(alias: "a.invalid", hostname: "alpha.invalid"),
        ])
        let connector = SSHConnector(resolver: resolver, localUser: "operator")
        var opened: [String] = []
        var refused: [SSHFailure] = []
        connector.begin(alias: "a.invalid", refusePersoHermes: true, opened: { config, _ in opened.append(config.alias) }, refused: { failure, _ in refused.append(failure) })
        await eventually { await resolver.started == ["a.invalid"] }
        connector.begin(alias: "bad alias", refusePersoHermes: true, opened: { config, _ in opened.append(config.alias) }, refused: { failure, _ in refused.append(failure) })
        XCTAssertEqual(refused, [.invalidHost])
        await resolver.release("a.invalid")
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(opened, [])
        let startedAfterInvalid = await resolver.started
        XCTAssertEqual(startedAfterInvalid, ["a.invalid"])
    }

    private func dump(_ extra: String = "") -> SSHConfigDump {
        SSHConfigDump(
            stdout: "user operator\nhostname gateway.invalid\nport 22\nidentityfile /tmp/fake-id.invalid\n\(extra)",
            stderr: "debug1: Applying options for lab.invalid\n"
        )
    }

    func testEverySshInvocationIsDumpedAndAValidAliasOpensWithTheTunnelPreview() async {
        let resolver = ScriptedSSHResolver(dumps: [.tunnel: dump(), .profileList: dump(), .profileLocks: dump()])
        let connector = SSHConnector(resolver: resolver, localUser: "operator")
        var opened: [String] = []
        var refused: [SSHFailure] = []
        connector.begin(alias: "lab.invalid", refusePersoHermes: true, opened: { config, _ in opened.append(config.alias) }, refused: { failure, _ in refused.append(failure) })
        await eventually { opened == ["lab.invalid"] }
        let asked = await resolver.asked
        XCTAssertEqual(asked, [.tunnel, .profileList, .profileLocks])
        XCTAssertEqual(refused, [])
    }

    /// Un relais que seul un lancement voit (`Match sessiontype none` pour le tunnel, `Match command` pour les lectures) est refusé, en mode test comme hors mode test
    func testARelayThatOnlyOneInvocationSeesIsRefusedInEveryMode() async {
        let relays: [(SSHInvocation, String)] = [
            (.tunnel, "proxyjump bastion.invalid"),
            (.profileList, "proxycommand /usr/bin/nc bastion.invalid 22"),
            (.profileLocks, "proxyjump bastion.invalid"),
        ]
        for refuse in [true, false] {
            for (invocation, relay) in relays {
                var dumps: [SSHInvocation: SSHConfigDump] = [.tunnel: dump(), .profileList: dump(), .profileLocks: dump()]
                dumps[invocation] = dump(relay)
                let connector = SSHConnector(resolver: ScriptedSSHResolver(dumps: dumps), localUser: "operator")
                var opened: [String] = []
                var refused: [SSHFailure] = []
                connector.begin(alias: "lab.invalid", refusePersoHermes: refuse, opened: { config, _ in opened.append(config.alias) }, refused: { failure, _ in refused.append(failure) })
                await eventually { !refused.isEmpty || !opened.isEmpty }
                XCTAssertEqual(refused, [.relayRefused], "\(invocation) refuse=\(refuse)")
                XCTAssertEqual(opened, [], "\(invocation) refuse=\(refuse)")
            }
        }
    }

    func testPersoHermesIsRefusedWithoutDumpingTheConfig() async {
        let resolver = GatedSSHResolver(dumps: [:])
        let connector = SSHConnector(resolver: resolver, localUser: "operator")
        var opened: [String] = []
        var refused: [SSHFailure] = []
        connector.begin(alias: "perso-hermes.invalid", refusePersoHermes: true, opened: { config, _ in opened.append(config.alias) }, refused: { failure, _ in refused.append(failure) })
        XCTAssertEqual(refused, [.forbiddenHost])
        XCTAssertEqual(opened, [])
        let started = await resolver.started
        XCTAssertEqual(started, [])
    }

    private func eventually(_ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition jamais vraie")
    }
}

/// Retient la résolution du tunnel jusqu'à `release` ; les deux autres lancements répondent tout de suite
private actor GatedSSHResolver: SSHConfigResolving {
    private let dumps: [String: SSHConfigDump]
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]
    private(set) var started: [String] = []

    init(dumps: [String: SSHConfigDump]) {
        self.dumps = dumps
    }

    func dump(alias: String, invocation: SSHInvocation) async throws -> SSHConfigDump {
        if invocation == .tunnel {
            started.append(alias)
            await withCheckedContinuation { gates[alias] = $0 }
        }
        return dumps[alias] ?? SSHConfigDump(stdout: "")
    }

    func release(_ alias: String) {
        gates[alias]?.resume()
        gates[alias] = nil
    }
}

/// Une sortie par lancement, rendue tout de suite ; `asked` garde l'ordre des demandes
private actor ScriptedSSHResolver: SSHConfigResolving {
    private let dumps: [SSHInvocation: SSHConfigDump]
    private(set) var asked: [SSHInvocation] = []

    init(dumps: [SSHInvocation: SSHConfigDump]) {
        self.dumps = dumps
    }

    func dump(alias: String, invocation: SSHInvocation) async throws -> SSHConfigDump {
        asked.append(invocation)
        return dumps[invocation] ?? SSHConfigDump(stdout: "")
    }
}
