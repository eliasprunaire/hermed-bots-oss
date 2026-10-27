import HermesAdapter
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

    /// Ligne verbatim de `ssh -G -vv` (OpenSSH 10.3) pour un bloc Host dont le motif couvre l'alias
    private func applying(_ pattern: String, line: Int = 3) -> String {
        "debug1: /tmp/config line \(line): Applying options for \(pattern)\n"
    }

    private var unmatchedDebug: String { "debug1: Reading configuration data /tmp/config\n" + applying("*") }
    private func matchedDebug(_ alias: String) -> String {
        applying(alias) + applying("*", line: 9)
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

    /// Ligne verbatim de `ssh -G -vv` (OpenSSH 10.3) : ssh l'écrit pour chaque ligne Match qu'il lit, qu'elle s'applique ou non
    private func matchDebug(_ criteria: String, alias: String = "lab", found: Bool = true) -> String {
        "debug2: checking match for '\(criteria)' host \(alias) originally \(alias)\ndebug2: match \(found ? "found" : "not found")\n"
    }

    /// Un bloc Match, quelle que soit sa forme, fait refuser la config : l'app n'interprète aucun critère
    func testAnyMatchBlockRefusesTheConfigWhateverItsCriteria() {
        let criteria = [
            "all", "user *", "host *", "originalhost *", "localuser *", "exec true", "host lab", "originalhost lab",
            #"exec "true \" host lab.invalid \"""#, "final all", "canonical host lab", "!host lab", "host la*,!lax", "all # host lab",
            "host \"lab",
        ]
        for text in criteria {
            for found in [true, false] {
                let debug = matchedDebug("lab") + matchDebug(text, found: found)
                let preview = parse(defaultDump, alias: "lab", debug: debug)
                XCTAssertTrue(preview.hasMatchBlock, "\(text) found=\(found)")
                XCTAssertThrowsError(try SSHConnectionPlanner.config(from: preview, refusePersoHermes: true), text) {
                    XCTAssertEqual($0 as? SSHFailure, .matchBlockRefused, text)
                }
            }
        }
    }

    func testAConfigWithoutMatchBlockIsNotRefusedForOne() {
        let preview = parse(defaultDump, alias: "lab", debug: matchedDebug("lab"))
        XCTAssertFalse(preview.hasMatchBlock)
        XCTAssertNoThrow(try SSHConnectionPlanner.config(from: preview, refusePersoHermes: true))
    }

    /// Seul un bloc Host qui écrit l'alias tel quel le rend connu
    func testAHostBlockThatNamesTheAliasLiterallyMakesItKnown() {
        for (pattern, alias) in [("monalias", "monalias"), ("lab.invalid", "lab.invalid")] {
            let preview = parse(defaultDump, alias: alias, debug: applying(pattern) + applying("*", line: 9))
            XCTAssertFalse(preview.isUnknownAlias, pattern)
            XCTAssertNoThrow(try SSHConnectionPlanner.config(from: preview, refusePersoHermes: true), pattern)
        }
    }

    /// Un motif avec joker, nié ou d'une autre casse ne nomme jamais l'alias, même s'il le couvre
    func testAHostPatternWithAWildcardNeverNamesTheAlias() {
        for pattern in ["*", "**", "mon*", "m?nalias", "*alias", "monali?s", "!monalias", "monalias,other", "MonAlias"] {
            let preview = parse(defaultDump, alias: "monalias", debug: applying(pattern))
            XCTAssertTrue(preview.isUnknownAlias, pattern)
            XCTAssertThrowsError(try SSHConnectionPlanner.config(from: preview, refusePersoHermes: true), pattern) {
                XCTAssertEqual($0 as? SSHFailure, .unknownAlias, pattern)
            }
        }
    }

    /// Une ligne que l'app ne lit pas avec certitude ne nomme pas l'alias : elle est refusée
    func testALogLineTheParserCannotReadWithCertaintyDoesNotNameTheAlias() {
        let lines = [
            "debug1: Applying options for monalias",
            "debug1: /tmp/config line 3: Applying options for monalias extra",
            "debug1: /tmp/config line 3: Applying options for  monalias",
            "debug1: /tmp/config line x: Applying options for monalias",
            "debug2: /tmp/config line 3: Applying options for monalias",
            "debug1: /tmp/config line 3: Applying options for \"monalias\"",
            "/tmp/config line 3: Applying options for monalias",
        ]
        for line in lines {
            let preview = parse(defaultDump, alias: "monalias", debug: line + "\n")
            XCTAssertTrue(preview.isUnknownAlias, line)
        }
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
            "proxyjump ssh://jump-alias.invalid,second.invalid",
            "proxyjump blocked@jump-alias.invalid",
            // OpenSSH ne lit `none` seul que comme valeur entière : dans une liste, c'est le nom d'un saut
            "proxyjump none,none",
            "proxyjump NONE,NONE",
            "proxyjump none,bastion.invalid",
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
            stderr: "debug1: /tmp/config line 3: Applying options for \(alias)\n"
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
            stderr: "debug1: /tmp/config line 3: Applying options for lab.invalid\n"
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

/// Le vrai `/usr/bin/ssh -G -vv -F <config>` : le format des lignes de débogage vient d'OpenSSH, pas d'un échantillon écrit à la main
final class RealSshConfigTests: XCTestCase {
    /// L'échec que l'app montrerait pour `config`, ou nil quand l'alias est accepté ; `$DIR` vaut le dossier des fichiers de la config
    private func failure(_ config: String, alias: String = "lab.invalid", files: [String: String] = [:]) async throws -> SSHFailure? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hb-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        for (name, text) in files.merging(["config": config], uniquingKeysWith: { $1 }) {
            try text.replacingOccurrences(of: "$DIR", with: directory.path).write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        do {
            let dump = try await SystemSSHConfigResolver(configFile: directory.appendingPathComponent("config").path).dump(alias: alias, invocation: .tunnel)
            let preview = SSHConfig.parse(dump, alias: alias, localUser: "operator")
            _ = try SSHConnectionPlanner.config(from: preview, refusePersoHermes: true)
            return nil
        } catch let failure as SSHFailure {
            return failure
        }
    }

    func testEveryFormOfMatchRefusesTheConfig() async throws {
        let forms = [
            "Match all", "match all", "Match\tall", "Match=all", "Match user *", "Match host *", "Match originalhost *", "Match localuser *",
            "Match exec true", #"Match exec "true \" host lab.invalid \"""#, "Match host lab.invalid", "Match originalhost lab.invalid",
            "Match final all", "Match canonical all", "Match all # host lab.invalid",
        ]
        for form in forms {
            for config in ["\(form)\nUser operator\n", "Host lab.invalid\n  User operator\n\(form)\n", "\(form)\nHost lab.invalid\n"] {
                let result = try await failure(config)
                XCTAssertEqual(result, .matchBlockRefused, config)
            }
        }
    }

    /// ssh lit la ligne Match d'un bloc Host qui ne s'applique pas, et d'un fichier inclus : la config est refusée aussi
    func testAMatchBlockThatDoesNotApplyToTheAliasStillRefusesTheConfig() async throws {
        let afterOtherHost = try await failure("Host lab.invalid\n  User operator\nHost other\n  User x\nMatch host other\n  User y\n")
        XCTAssertEqual(afterOtherHost, .matchBlockRefused)
        let included = try await failure("Host lab.invalid\nHost other\n  Include $DIR/inc.conf\n", files: ["inc.conf": "Match all\n"])
        XCTAssertEqual(included, .matchBlockRefused)
        let notMatching = try await failure("Host lab.invalid\nMatch originalhost other\n")
        XCTAssertEqual(notMatching, .matchBlockRefused)
    }

    func testAHostBlockNamesTheAliasOnlyByItsLiteralName() async throws {
        let named = ["Host lab.invalid", "Host other lab.invalid", #"Host "lab.invalid""#, "Host *\nHost lab.invalid\n  User operator", "Host lab.invalid\n  User operator"]
        for config in named {
            let result = try await failure(config + "\n")
            XCTAssertNil(result, config)
        }
        let monalias = try await failure("Host monalias\n", alias: "monalias")
        XCTAssertNil(monalias)
        let unnamed = [
            "Host *\n  User operator", "Host **", "Host lab.*\n  User operator", "Host lab.inval?d", "Host *.invalid",
            "Host * lab.invalid", "Host Lab.invalid", "Host lab.invalid !lab.invalid", "Host !other *\n  User operator",
        ]
        for config in unnamed {
            let result = try await failure(config + "\n")
            XCTAssertEqual(result, .unknownAlias, config)
        }
        let byPattern = try await failure("Host mon*\n  User operator\n", alias: "monalias")
        XCTAssertEqual(byPattern, .unknownAlias)
        let noBlock = try await failure("User operator\n")
        XCTAssertEqual(noBlock, .unknownAlias)
    }

    /// Guillemet non fermé, option inconnue, argument manquant : ssh sort en erreur, la config est refusée
    func testAConfigThatSshCannotParseIsRefused() async throws {
        for config in ["Host \"lab\n", "Match\n", "Match exec\n", "Match bogus x\n", "Bogus yes\n", "Host lab.invalid\n  ProxyJump\n", "Host lab.invalid\n  Port\n"] {
            let result = try await failure(config)
            XCTAssertEqual(result, .unreadableConfig, config)
        }
    }

    /// Un `Include` qui ne désigne aucun fichier est un doute : refus
    func testAnIncludeThatMatchesNoFileRefusesTheConfig() async throws {
        let missing = try await failure("Host lab.invalid\nInclude $DIR/missing/*\n")
        XCTAssertEqual(missing, .unreadableConfig)
        let present = try await failure("Host lab.invalid\nInclude $DIR/inc.conf\n", files: ["inc.conf": "User operator\n"])
        XCTAssertNil(present)
    }

    /// Le journal est coupé à 64 Ko : un Match au-delà de la coupure ne doit pas faire accepter la config
    func testALogCutAtTheLimitRefusesTheConfig() async throws {
        let config = "Host lab.invalid\n" + String(repeating: "Include $DIR/empty.conf\n", count: 1500) + "Match all\n"
        let result = try await failure(config, files: ["empty.conf": "\n"])
        XCTAssertEqual(result, .unreadableConfig)
    }
}

#if DEBUG
private final class ConnectSpyStore: SecretStore {
    func apiKey(profile: String) throws -> String? {
        XCTFail("KeychainSecretStore appelé")
        return nil
    }

    func setAPIKey(_ key: String, profile: String) throws {
        XCTFail("KeychainSecretStore appelé")
    }
}

@MainActor
final class AppModelConnectTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        let name = "hd07-appmodel-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private func knownDump(alias: String, hostname: String) -> SSHConfigDump {
        SSHConfigDump(
            stdout: """
            user operator
            hostname \(hostname)
            port 22
            identityfile /tmp/fake-id.invalid
            proxyjump none
            """,
            stderr: "debug1: /tmp/config line 3: Applying options for \(alias)\n"
        )
    }

    func testAnEmptySecondRequestOnAppModelNeverOpensTheFirstTunnel() async {
        let resolver = GatedSSHResolver(dumps: [
            "a.invalid": knownDump(alias: "a.invalid", hostname: "alpha.invalid"),
        ])
        let environment = AppEnvironment.resolve(["HV_TEST_MODE": "1"], defaults: isolatedDefaults(), keychain: { InMemorySecretStore(apiKey: nil) })
        let model = AppModel(environment: environment, sshResolver: resolver)
        model.host = "a.invalid"
        model.connect()
        await eventually { await resolver.started == ["a.invalid"] }
        model.host = ""
        model.connect()
        if case .failed(let failure) = model.tunnel.state {
            XCTAssertEqual(failure, .invalidHost)
        } else {
            XCTFail("attendu invalidHost, obtenu \(model.tunnel.state)")
        }
        await resolver.release("a.invalid")
        try? await Task.sleep(for: .milliseconds(80))
        if case .failed(let failure) = model.tunnel.state {
            XCTAssertEqual(failure, .invalidHost)
        } else {
            XCTFail("A a ouvert un tunnel périmé : \(model.tunnel.state)")
        }
        let started = await resolver.started
        XCTAssertEqual(started, ["a.invalid"])
    }

    func testPersoHermesOnAppModelNeverDumpsOrOpens() async {
        let resolver = GatedSSHResolver(dumps: [
            "perso-hermes.invalid": knownDump(alias: "perso-hermes.invalid", hostname: "perso-hermes.invalid"),
        ])
        let environment = AppEnvironment.resolve(
            ["HV_TEST_MODE": "1", "HV_SSH_HOST": "perso-hermes.invalid"],
            defaults: isolatedDefaults(),
            keychain: { InMemorySecretStore(apiKey: nil) }
        )
        let model = AppModel(environment: environment, sshResolver: resolver)
        try? await Task.sleep(for: .milliseconds(40))
        let startedAtLaunch = await resolver.started
        XCTAssertEqual(startedAtLaunch, [])
        model.connect()
        let startedAfterConnect = await resolver.started
        XCTAssertEqual(startedAfterConnect, [])
        if case .failed(let failure) = model.tunnel.state {
            XCTAssertEqual(failure, .forbiddenHost)
        } else {
            XCTFail("\(model.tunnel.state)")
        }
    }

    func testConnectNeverReadsTheKeychainAndOpensWithTheAlias() async {
        let dumps = knownDump(alias: "lab.invalid", hostname: "gateway.invalid")
        let resolver = ScriptedSSHResolver(dumps: [.tunnel: dumps, .profileList: dumps, .profileLocks: dumps])
        let environment = AppEnvironment.resolve([:], defaults: isolatedDefaults(), keychain: { ConnectSpyStore() })
        let model = AppModel(environment: environment, sshResolver: resolver)
        model.host = "lab.invalid"
        model.connect()
        await eventually {
            switch model.tunnel.state {
            case .opening, .open, .failed, .reopening: true
            case .idle: false
            }
        }
        let args = try! SSHTunnelConfig(alias: "lab.invalid", hostname: "gateway.invalid", user: "operator", refusePersoHermes: false).arguments(localPort: 1)
        XCTAssertEqual(args.last, "lab.invalid")
        XCTAssertNil(args.firstIndex(of: "-i"))
        await model.tunnel.stop()
    }

    private func keyModel(keys: [String: String] = [:], profiles: [String], reads: KeyReads, serve: @escaping @Sendable (URLRequest) -> Int) -> AppModel {
        let table = (["Profile  Model  Gateway  Alias  Distribution"] + profiles.map { "  \($0)   hv-fake-1   running   —   —" }).joined(separator: "\n")
        let environment = AppEnvironment.resolve(
            [
                "HV_TEST_MODE": "1",
                "HV_API_URL": "http://hermes.invalid",
                "HV_TEST_PROFILE_TABLE": table,
                "HV_TEST_API_KEYS": String(decoding: try! JSONEncoder().encode(keys), as: UTF8.self),
            ],
            defaults: isolatedDefaults(),
            keychain: { InMemorySecretStore(apiKey: nil) }
        )
        KeyStubProtocol.serve = serve
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KeyStubProtocol.self]
        return AppModel(environment: environment, apiKeyReader: reads.read, urlConfiguration: configuration)
    }

    private func refusal(_ status: Int = 401) -> HermesError { .http(contract: "list_sessions", status: status, detail: nil) }

    /// `/health` est public sur Hermes : une réponse de `/health` ne prouve pas que la clé est acceptée
    func testAKeyThatHermesKeepsRefusingIsReadOverSSHOnceAndNotAtEveryHealthCheck() async {
        let reads = KeyReads { count, _ in count <= 3 ? "short-key" : nil }
        let model = keyModel(profiles: ["hv-bot-a"], reads: reads) { $0.url?.path.hasSuffix("/health") == true ? 200 : 401 }
        await model.bots.refresh()
        await model.refreshVersion()
        XCTAssertEqual(reads.profiles, ["hv-bot-a"])
        XCTAssertEqual(model.apiError, HermesAPIKey.unauthorizedMessage(profile: "hv-bot-a", holdsKey: true))
        XCTAssertFalse(model.isCheckingAPI)
    }

    func testRetryReadsTheKeyOfTheRefusedProfileAndNotOfTheOneOnScreen() async {
        let reads = KeyReads { count, _ in count == 1 ? nil : "key-a" }
        let model = keyModel(keys: ["hv-bot-b": "key-b"], profiles: ["hv-bot-b", "hv-bot-a"], reads: reads) { _ in 200 }
        await model.bots.refresh()
        XCTAssertEqual(model.versionProfile, "hv-bot-b")
        await model.handleAPIError(refusal(), profile: "hv-bot-a")
        XCTAssertEqual(reads.profiles, ["hv-bot-a"])
        XCTAssertEqual(model.apiError, HermesAPIKey.missingMessage(profile: "hv-bot-a"))
        await model.retryAPI()
        XCTAssertEqual(reads.profiles, ["hv-bot-a", "hv-bot-a"])
        XCTAssertNil(model.apiError)
    }

    func testRetryKeepsTheBannerOfTheRefusedProfileWhileItsKeyStaysUnreadable() async {
        let reads = KeyReads { _, _ in nil }
        let model = keyModel(keys: ["hv-bot-b": "key-b"], profiles: ["hv-bot-b", "hv-bot-a"], reads: reads) { _ in 200 }
        await model.bots.refresh()
        await model.handleAPIError(refusal(), profile: "hv-bot-a")
        await model.retryAPI()
        XCTAssertEqual(reads.profiles, ["hv-bot-a", "hv-bot-a"])
        XCTAssertEqual(model.apiError, HermesAPIKey.missingMessage(profile: "hv-bot-a"))
    }

    func testRetryAfterAnErrorThatIsNotARefusalChecksTheProfileOnScreenWithoutReadingAKey() async {
        let reads = KeyReads { _, _ in "key" }
        let model = keyModel(keys: ["hv-bot-b": "key-b"], profiles: ["hv-bot-b"], reads: reads) { _ in 200 }
        await model.bots.refresh()
        await model.handleAPIError(HermesError.unreachable(url: "", reason: "délai"), profile: "hv-bot-b")
        XCTAssertNotNil(model.apiError)
        await model.retryAPI()
        XCTAssertNil(model.apiError)
        XCTAssertEqual(reads.profiles, [])
    }

    /// Un dépli lance `list_sessions` avant que la clé soit en cache : les fils restent en échec tant que rien ne les relit
    func testThreadsExpandedBeforeTheKeyIsCachedAreReadAgainOnceTheKeyIsFetched() async {
        let reads = KeyReads { _, _ in "key-a" }
        let model = keyModel(profiles: ["hv-bot-a"], reads: reads) { request in
            let open = request.url?.path.hasSuffix("/health") == true || request.value(forHTTPHeaderField: "Authorization") == "Bearer key-a"
            return open ? 200 : 401
        }
        await model.bots.refresh()
        model.bots.toggle("hv-bot-a")
        await eventually {
            if case .failed? = model.bots.threads["hv-bot-a"] { return true }
            return false
        }
        XCTAssertEqual(reads.profiles, [])
        await model.refreshVersion()
        XCTAssertEqual(reads.profiles, ["hv-bot-a"])
        await eventually { model.bots.threads["hv-bot-a"] == .loaded([]) }
        XCTAssertNil(model.apiError)
    }

    /// Un bot replié n'est pas lu : la clé récupérée ne déplie rien
    func testAFetchedKeyDoesNotReadThreadsOfABotThatIsCollapsed() async {
        let reads = KeyReads { _, _ in "key-a" }
        let model = keyModel(profiles: ["hv-bot-a"], reads: reads) { request in
            let open = request.url?.path.hasSuffix("/health") == true || request.value(forHTTPHeaderField: "Authorization") == "Bearer key-a"
            return open ? 200 : 401
        }
        await model.bots.refresh()
        await model.refreshVersion()
        XCTAssertEqual(reads.profiles, ["hv-bot-a"])
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(model.bots.threads["hv-bot-a"])
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

/// Lectures SSH de `API_SERVER_KEY` simulées : garde les profils lus, dans l'ordre ; `answer` rend la clé de la n-ième lecture, nil est un échec
@MainActor
private final class KeyReads {
    private(set) var profiles: [String] = []
    private let answer: (Int, String) -> String?

    init(_ answer: @escaping (Int, String) -> String?) { self.answer = answer }

    func read(_ profile: String) async throws -> String? {
        profiles.append(profile)
        guard let key = answer(profiles.count, profile) else { throw SSHFailure.unreachable("simulé") }
        return key
    }
}

/// Un faux Hermes sans réseau : `serve` donne le statut de chaque requête, le corps est une version connue et une liste de fils vide
private final class KeyStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var serve: (@Sendable (URLRequest) -> Int)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let status = Self.serve?(request) ?? 500
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"version":"0.22.1","data":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
