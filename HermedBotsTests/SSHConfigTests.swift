import AppSettings
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

    private func parse(_ dump: String, alias: String, existing: Set<String> = [], authSock: String? = nil) -> SSHConnectionPreview {
        SSHConfig.parse(
            dump,
            alias: alias,
            localUser: localUser,
            filesExist: { existing.contains($0) },
            authSock: authSock
        )
    }

    func testAnIncludedHostBlockResolvesEveryFieldWithoutSecrets() {
        let preview = parse(includedDump, alias: "lab", existing: ["/tmp/fake-id.invalid-cert.pub"])
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
        XCTAssertNoThrow(try SSHConnectionPlanner.config(from: preview, refuseTestHost: true))
    }

    func testParseReadsANonDefaultPortFromSshG() {
        let preview = parse(
            """
            user operator
            hostname example.invalid
            port 2200
            identityfile /tmp/fake-id.invalid
            proxyjump none
            """,
            alias: "example.invalid"
        )
        XCTAssertEqual(preview.port, 2200)
        XCTAssertEqual(preview.hostname, "example.invalid")
    }

    func testParseTreatsAMissingPortLineAsTheOpenSSHDefault() {
        let preview = parse(
            """
            user operator
            hostname example.invalid
            identityfile /tmp/fake-id.invalid
            proxyjump none
            """,
            alias: "example.invalid"
        )
        XCTAssertEqual(preview.port, 22)
        XCTAssertEqual(preview.hostname, "example.invalid")
    }

    func testSshGStdoutIsAcceptedEvenWhenOnlyDefaultIdentitiesAppear() {
        let preview = parse(defaultDump, alias: "unknown-alias.invalid")
        XCTAssertEqual(preview.hostname, "unknown-alias.invalid")
        XCTAssertEqual(preview.port, 22)
        XCTAssertFalse(preview.hasRelay)
        XCTAssertEqual(preview.identity, .file)
        XCTAssertFalse(preview.identityPresent)
        XCTAssertNoThrow(try SSHConnectionPlanner.config(from: preview, refuseTestHost: true))
    }

    func testAMissingPublicKeyOnDiskDoesNotRefuseTheAlias() {
        let dump = """
            user hermes
            hostname lab.invalid
            port 22
            identityfile /tmp/fake-id.invalid
            identityfile ~/.ssh/id_rsa
            proxyjump none
            """
        let preview = parse(dump, alias: "lab.invalid")
        XCTAssertEqual(preview.identity, .file)
        XCTAssertFalse(preview.identityPresent)
        XCTAssertEqual(preview.identityPresentTitle, "Clé publique")
        XCTAssertEqual(preview.identityPresentLabel, "absente")
        XCTAssertNoThrow(try SSHConnectionPlanner.config(from: preview, refuseTestHost: true))
    }

    func testEphemeralModeShowsAgentInsteadOfDefaultIdentityFiles() {
        let session = parse(defaultDump, alias: "unknown-alias.invalid")
        XCTAssertEqual(session.identity, .file)
        let launch = session.matchingLaunch(mode: .ephemeralAgent, keyCommandSet: true)
        XCTAssertEqual(launch.identity, .agent)
        XCTAssertEqual(launch.identity.label, "agent SSH")
        XCTAssertTrue(launch.identityPresent)
        XCTAssertFalse(launch.identity.label.contains("/tmp"))
        XCTAssertEqual(session.matchingLaunch(mode: .sessionAgent, keyCommandSet: false).identity, .file)
    }

    func testAPresentPublicKeyIsOnlyALabel() {
        let dump = """
            user hermes
            hostname lab.invalid
            port 22
            identityfile /tmp/fake-id.invalid
            identityfile ~/.ssh/id_rsa
            proxyjump none
            """
        let preview = parse(dump, alias: "lab.invalid", existing: ["/tmp/fake-id.invalid.pub"])
        XCTAssertEqual(preview.identity, .file)
        XCTAssertTrue(preview.identityPresent)
        XCTAssertEqual(preview.identityPresentLabel, "présente")
        XCTAssertNoThrow(try SSHConnectionPlanner.config(from: preview, refuseTestHost: true))
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

    func testTheResolvedExampleHostHostIsRefusedInTestMode() {
        let dump = """
            user operator
            hostname example-host.invalid
            port 22
            identityfile /tmp/fake-id.invalid
            """
        let preview = parse(dump, alias: "lab.invalid")
        XCTAssertThrowsError(try SSHConnectionPlanner.config(from: preview, refuseTestHost: true)) {
            XCTAssertEqual($0 as? SSHFailure, .forbiddenHost)
        }
        XCTAssertNoThrow(try SSHConnectionPlanner.config(from: preview, refuseTestHost: false))
    }

    func testExampleHostAliasIsRefusedInTestMode() {
        let dump = defaultDump.replacingOccurrences(of: "unknown-alias.invalid", with: "example-host.invalid")
        let preview = parse(dump, alias: "example-host.invalid")
        XCTAssertThrowsError(try SSHConnectionPlanner.config(from: preview, refuseTestHost: true)) {
            XCTAssertEqual($0 as? SSHFailure, .forbiddenHost)
        }
    }

    func testIdentityAgentNoneUsesNoAgentEvenWithASessionSocket() {
        for value in ["none", "NONE"] {
            let standard = parse(
                defaultDump + "\nidentityagent \(value)",
                alias: "lab.invalid",
                existing: [NSHomeDirectory() + "/.ssh/id_ed25519", "/tmp/example-agent.invalid"],
                authSock: "/tmp/example-agent.invalid"
            )
            XCTAssertEqual(standard.identity, .file, value)
            XCTAssertNotEqual(standard.identity.label, "agent SSH", value)
            XCTAssertTrue(standard.identityPresent, value)
            let custom = parse(
                "user operator\nhostname lab.invalid\nport 22\nidentityagent \(value)\nidentityfile /tmp/fake-id.invalid",
                alias: "lab.invalid",
                existing: ["/tmp/example-agent.invalid"],
                authSock: "/tmp/example-agent.invalid"
            )
            XCTAssertEqual(custom.identity, .file, value)
            XCTAssertFalse(custom.identityPresent, "\(value) : seule la socket existe, et l'agent est désactivé")
            XCTAssertNoThrow(try SSHConnectionPlanner.config(from: custom, refuseTestHost: true), value)
        }
    }

    func testAnyProxyJumpOrProxyCommandIsRefusedInEveryMode() {
        let relays = [
            "proxyjump bastion.invalid",
            "proxyjump operator@bastion.invalid:2222,second.invalid",
            "proxyjump example-host.invalid",
            "proxyjump -",
            "proxyjump ssh://jump-alias.invalid,second.invalid",
            "proxyjump blocked@jump-alias.invalid",
            "proxyjump none,none",
            "proxyjump NONE,NONE",
            "proxyjump none,bastion.invalid",
            "proxycommand /usr/bin/nc bastion.invalid 22",
            "proxycommand /usr/bin/ssh -W %h:%p example-host.invalid",
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
            let preview = parse(dump, alias: "lab.invalid")
            XCTAssertTrue(preview.hasRelay, relay)
            for refuse in [true, false] {
                XCTAssertThrowsError(try SSHConnectionPlanner.config(from: preview, refuseTestHost: refuse), relay) {
                    XCTAssertEqual($0 as? SSHFailure, .relayRefused, relay)
                }
            }
        }
    }

    func testNoneIsNotARelay() {
        let preview = parse(includedDump, alias: "lab", existing: ["/tmp/fake-id.invalid-cert.pub"])
        XCTAssertFalse(preview.hasRelay)
        XCTAssertNoThrow(try SSHConnectionPlanner.config(from: preview, refuseTestHost: false))
    }

    func testResolutionArgumentsAreDashGPlusTheLaunchAndNeverDashVv() throws {
        let config = try SSHTunnelConfig(alias: "lab.invalid", hostname: "gateway.invalid", user: "operator", refuseTestHost: true)
        let launched: [SSHInvocation: [String]] = [
            .tunnel: config.arguments(localPort: 1),
            .profileList: config.profileListArguments(),
            .profileLocks: config.profileLocksArguments(),
        ]
        for invocation in SSHInvocation.allCases {
            let args = SystemSSHConfigResolver.arguments(alias: "lab.invalid", invocation: invocation)
            XCTAssertEqual(args, ["-G"] + launched[invocation]!, "\(invocation)")
            XCTAssertFalse(args.contains("-vv"), "\(invocation)")
        }
        XCTAssertTrue(SystemSSHConfigResolver.arguments(alias: "lab.invalid", invocation: .tunnel).contains("-N"))
        XCTAssertFalse(SystemSSHConfigResolver.arguments(alias: "lab.invalid", invocation: .profileList).contains("-N"))
        XCTAssertEqual(
            SystemSSHConfigResolver.arguments(alias: "lab.invalid", invocation: .tunnel, configFile: "/tmp/fake-ssh.invalid").prefix(3).map { $0 },
            ["-G", "-F", "/tmp/fake-ssh.invalid"]
        )
    }

    func testResolutionCarriesTheTemporaryAgentOfTheLaunch() throws {
        let socket = "/tmp/example-agent.invalid/a"
        let config = try SSHTunnelConfig(alias: "lab.invalid", hostname: "gateway.invalid", user: "operator", refuseTestHost: true)
        let launched: [SSHInvocation: [String]] = [
            .tunnel: config.arguments(localPort: 1),
            .profileList: config.profileListArguments(),
            .profileLocks: config.profileLocksArguments(),
        ]
        for invocation in SSHInvocation.allCases {
            let args = SystemSSHConfigResolver.arguments(alias: "lab.invalid", invocation: invocation, agentSocket: socket)
            XCTAssertEqual(args, ["-G"] + SSHTunnelConfig.withIdentityAgent(launched[invocation]!, socket: socket), "\(invocation)")
        }
        let key = try SystemSSHConfigResolver.apiKeyArguments(alias: "lab.invalid", profile: "hv-bot-a", agentSocket: socket)
        XCTAssertEqual(key, ["-G"] + SSHTunnelConfig.withIdentityAgent(try config.apiKeyArguments(profile: "hv-bot-a"), socket: socket))
        XCTAssertFalse(SystemSSHConfigResolver.arguments(alias: "lab.invalid", invocation: .tunnel).contains { $0.hasPrefix("IdentityAgent=") })
        let session = ["HOME": "/tmp/example-home", "SSH_AUTH_SOCK": "/tmp/session.invalid/agent", "HV_TEST_SSH_KEY": "x"]
        XCTAssertEqual(SSHChildEnvironment.make(session, agentSocket: socket)["SSH_AUTH_SOCK"], socket)
        XCTAssertEqual(SSHChildEnvironment.make(session)["SSH_AUTH_SOCK"], "/tmp/session.invalid/agent")
        XCTAssertNil(SSHChildEnvironment.make(session, agentSocket: socket)["IdentityAgent"])
        XCTAssertNil(SSHChildEnvironment.make(session, agentSocket: socket)["HV_TEST_SSH_KEY"])
    }

    func testAPIKeyResolutionArgumentsAreTheExactProfileCommand() throws {
        let args = try SystemSSHConfigResolver.apiKeyArguments(alias: "lab.invalid", profile: "hv-bot-a")
        XCTAssertEqual(args.first, "-G")
        XCTAssertFalse(args.contains("-vv"))
        XCTAssertEqual(Array(args.suffix(7)), ["hermes", "-p", "hv-bot-a", "config", "get", "API_SERVER_KEY", "--raw"])
        XCTAssertEqual(try SystemSSHConfigResolver.apiKeyArguments(alias: "lab.invalid", profile: "hv-bot-b").suffix(7).contains("hv-bot-a"), false)
    }

    func testAnAPIKeyDumpThatAddsARelayIsRefused() {
        let preview = parse(
            "user operator\nhostname gateway.invalid\nport 22\nidentityfile /tmp/fake-id.invalid\nproxyjump bastion.invalid\n",
            alias: "lab.invalid"
        )
        XCTAssertThrowsError(try SSHConnectionPlanner.config(from: preview, refuseTestHost: true)) {
            XCTAssertEqual($0 as? SSHFailure, .relayRefused)
        }
        XCTAssertThrowsError(try SSHConnectionPlanner.config(from: preview, refuseTestHost: false)) {
            XCTAssertEqual($0 as? SSHFailure, .relayRefused)
        }
    }

    func testAnAPIKeyDumpThatResolvesExampleHostIsRefusedInTestMode() {
        let preview = parse(
            "user operator\nhostname example-host.invalid\nport 22\nidentityfile /tmp/fake-id.invalid\nproxyjump none\n",
            alias: "lab.invalid"
        )
        XCTAssertThrowsError(try SSHConnectionPlanner.config(from: preview, refuseTestHost: true)) {
            XCTAssertEqual($0 as? SSHFailure, .forbiddenHost)
        }
    }

    func testAnAPIKeyDumpThatChangesTheTunnelDestinationIsRefused() throws {
        let tunnel = try SSHTunnelConfig(alias: "lab.invalid", hostname: "gateway.invalid", user: "operator", refuseTestHost: true)
        let same = parse(
            "user operator\nhostname gateway.invalid\nport 22\nidentityfile /tmp/fake-id.invalid\nproxyjump none\n",
            alias: "lab.invalid"
        )
        XCTAssertNoThrow(try SSHConnectionPlanner.config(from: same, refuseTestHost: true, matching: tunnel))
        let shifts = [
            "user operator\nhostname other.example.invalid\nport 22\nidentityfile /tmp/fake-id.invalid\nproxyjump none\n",
            "user other\nhostname gateway.invalid\nport 22\nidentityfile /tmp/fake-id.invalid\nproxyjump none\n",
            "user operator\nhostname gateway.invalid\nport 2222\nidentityfile /tmp/fake-id.invalid\nproxyjump none\n",
        ]
        for dump in shifts {
            let preview = parse(dump, alias: "lab.invalid")
            XCTAssertThrowsError(try SSHConnectionPlanner.config(from: preview, refuseTestHost: true, matching: tunnel), dump) {
                XCTAssertEqual($0 as? SSHFailure, .routeMismatch, dump)
            }
            XCTAssertThrowsError(try SSHConnectionPlanner.config(from: preview, refuseTestHost: false, matching: tunnel), dump) {
                XCTAssertEqual($0 as? SSHFailure, .routeMismatch, dump)
            }
        }
    }
}

/// Un fichier qui existe sur tout hôte : l'aperçu ne teste que sa présence, ssh ne le lit pas dans ces tests
private let existingIdentityFile = "/dev/null"

/// Un fichier d'identité qui n'existe pas : l'aperçu le donne pour absent
private let missingIdentityFile = "/tmp/fake-id.invalid"

@MainActor
final class SSHConnectorTests: XCTestCase {
    private func knownDump(hostname: String) -> SSHConfigDump {
        SSHConfigDump(
            stdout: """
            user operator
            hostname \(hostname)
            port 22
            identityfile \(existingIdentityFile)
            proxyjump none
            """
        )
    }

    func testALaterConnectIgnoresAStaleResolution() async {
        let resolver = GatedSSHResolver(dumps: [
            "a.invalid": knownDump(hostname: "alpha.invalid"),
            "b.invalid": knownDump(hostname: "beta.invalid"),
        ])
        let connector = SSHConnector(resolver: resolver, localUser: "operator")
        var opened: [String] = []
        var refused: [SSHFailure] = []
        connector.begin(alias: "a.invalid", refuseTestHost: true, opened: { config, _ in opened.append(config.alias) }, refused: { failure, _ in refused.append(failure) })
        await eventually { await resolver.started == ["a.invalid"] }
        connector.begin(alias: "b.invalid", refuseTestHost: true, opened: { config, _ in opened.append(config.alias) }, refused: { failure, _ in refused.append(failure) })
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
            "a.invalid": knownDump(hostname: "alpha.invalid"),
        ])
        let connector = SSHConnector(resolver: resolver, localUser: "operator")
        var opened: [String] = []
        var refused: [SSHFailure] = []
        connector.begin(alias: "a.invalid", refuseTestHost: true, opened: { config, _ in opened.append(config.alias) }, refused: { failure, _ in refused.append(failure) })
        await eventually { await resolver.started == ["a.invalid"] }
        connector.begin(alias: "   ", refuseTestHost: true, opened: { config, _ in opened.append(config.alias) }, refused: { failure, _ in refused.append(failure) })
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
            "a.invalid": knownDump(hostname: "alpha.invalid"),
        ])
        let connector = SSHConnector(resolver: resolver, localUser: "operator")
        var opened: [String] = []
        var refused: [SSHFailure] = []
        connector.begin(alias: "a.invalid", refuseTestHost: true, opened: { config, _ in opened.append(config.alias) }, refused: { failure, _ in refused.append(failure) })
        await eventually { await resolver.started == ["a.invalid"] }
        connector.begin(alias: "bad alias", refuseTestHost: true, opened: { config, _ in opened.append(config.alias) }, refused: { failure, _ in refused.append(failure) })
        XCTAssertEqual(refused, [.invalidHost])
        await resolver.release("a.invalid")
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(opened, [])
        let startedAfterInvalid = await resolver.started
        XCTAssertEqual(startedAfterInvalid, ["a.invalid"])
    }

    func testAnEphemeralConnectPreviewIsAgentWhenTheDumpListsFiles() async {
        let dump = knownDump(hostname: "gateway.invalid")
        let resolver = ScriptedSSHResolver(dumps: [.tunnel: dump, .profileList: dump, .profileLocks: dump])
        let connector = SSHConnector(resolver: resolver, localUser: "operator")
        var identity: SSHIdentityKind?
        connector.begin(
            alias: "lab.invalid",
            refuseTestHost: true,
            authMode: .ephemeralAgent,
            keyCommandSet: true,
            opened: { _, preview in identity = preview.identity },
            refused: { _, _ in }
        )
        await eventually { identity != nil }
        XCTAssertEqual(identity, .agent)
    }

    func testEverySshInvocationIsDumpedAndAValidAliasOpensWithTheTunnelPreview() async {
        let dump = knownDump(hostname: "gateway.invalid")
        let resolver = ScriptedSSHResolver(dumps: [.tunnel: dump, .profileList: dump, .profileLocks: dump])
        let connector = SSHConnector(resolver: resolver, localUser: "operator")
        var opened: [String] = []
        var refused: [SSHFailure] = []
        connector.begin(alias: "lab.invalid", refuseTestHost: true, opened: { config, _ in opened.append(config.alias) }, refused: { failure, _ in refused.append(failure) })
        await eventually { opened == ["lab.invalid"] }
        let asked = await resolver.asked
        XCTAssertEqual(asked, [.tunnel, .profileList, .profileLocks])
        XCTAssertEqual(refused, [])
    }

    func testARelayThatOnlyOneInvocationSeesIsRefusedInEveryMode() async {
        let clean = knownDump(hostname: "gateway.invalid")
        let relay = SSHConfigDump(
            stdout: "user operator\nhostname gateway.invalid\nport 22\nidentityfile /tmp/fake-id.invalid\nproxyjump bastion.invalid\n"
        )
        let relays: [(SSHInvocation, SSHConfigDump)] = [
            (.tunnel, relay),
            (.profileList, relay),
            (.profileLocks, relay),
        ]
        for refuse in [true, false] {
            for (invocation, extra) in relays {
                var dumps: [SSHInvocation: SSHConfigDump] = [.tunnel: clean, .profileList: clean, .profileLocks: clean]
                dumps[invocation] = extra
                let connector = SSHConnector(resolver: ScriptedSSHResolver(dumps: dumps), localUser: "operator")
                var opened: [String] = []
                var refused: [SSHFailure] = []
                connector.begin(alias: "lab.invalid", refuseTestHost: refuse, opened: { config, _ in opened.append(config.alias) }, refused: { failure, _ in refused.append(failure) })
                await eventually { !refused.isEmpty || !opened.isEmpty }
                XCTAssertEqual(refused, [.relayRefused], "\(invocation) refuse=\(refuse)")
                XCTAssertEqual(opened, [], "\(invocation) refuse=\(refuse)")
            }
        }
    }

    private struct Outcome {
        var opened: [String] = []
        var refused: [SSHFailure] = []
        var preview: SSHConnectionPreview?
    }

    private func outcome(of dump: SSHConfigDump, authMode: SSHAuthMode, keyCommandSet: Bool = false) async -> Outcome {
        let resolver = ScriptedSSHResolver(dumps: [.tunnel: dump, .profileList: dump, .profileLocks: dump])
        let connector = SSHConnector(resolver: resolver, localUser: "operator", authSock: nil)
        var result = Outcome()
        connector.begin(
            alias: "lab.invalid",
            refuseTestHost: true,
            authMode: authMode,
            keyCommandSet: keyCommandSet,
            opened: { config, preview in
                result.opened.append(config.alias)
                result.preview = preview
            },
            refused: { failure, preview in
                result.refused.append(failure)
                result.preview = preview
            }
        )
        await eventually { !result.opened.isEmpty || !result.refused.isEmpty }
        return result
    }

    private func dump(identityFile: String, extra: String = "") -> SSHConfigDump {
        SSHConfigDump(stdout: "user operator\nhostname gateway.invalid\nport 22\n\(extra)identityfile \(identityFile)\nproxyjump none\n")
    }

    func testNoIdentityIsRefusedBeforeLaunchInSessionMode() async {
        let missing = await outcome(of: dump(identityFile: missingIdentityFile), authMode: .sessionAgent)
        XCTAssertEqual(missing.refused, [.noIdentity])
        XCTAssertEqual(missing.opened, [])
        XCTAssertEqual(missing.preview?.identityPresent, false, "l'aperçu reste affiché avec l'identité absente")
        // une identité présente laisse ouvrir
        let present = await outcome(of: dump(identityFile: existingIdentityFile), authMode: .sessionAgent)
        XCTAssertEqual(present.refused, [])
        XCTAssertEqual(present.opened, ["lab.invalid"])
        // le mode Exécutable porte sa propre identité : aucune garde
        let wrapper = await outcome(of: dump(identityFile: missingIdentityFile), authMode: .wrapper)
        XCTAssertEqual(wrapper.refused, [])
        XCTAssertEqual(wrapper.opened, ["lab.invalid"])
    }

    func testEphemeralWithoutKeyCommandOrAgentIsRefusedBeforeLaunch() async {
        // le fichier d'identité du dump ne compte pas : l'agent temporaire n'en lit aucun
        let files = dump(identityFile: existingIdentityFile)
        let none = await outcome(of: files, authMode: .ephemeralAgent, keyCommandSet: false)
        XCTAssertEqual(none.refused, [.noIdentity])
        XCTAssertEqual(none.opened, [])
        let command = await outcome(of: files, authMode: .ephemeralAgent, keyCommandSet: true)
        XCTAssertEqual(command.refused, [])
        XCTAssertEqual(command.opened, ["lab.invalid"])
        let agent = await outcome(of: dump(identityFile: existingIdentityFile, extra: "identityagent /tmp/fake-agent.invalid\n"), authMode: .ephemeralAgent, keyCommandSet: false)
        XCTAssertEqual(agent.refused, [])
        XCTAssertEqual(agent.opened, ["lab.invalid"])
    }

    func testARelayIsRefusedBeforeTheIdentityIsChecked() async {
        let relayWithoutIdentity = SSHConfigDump(stdout: "user operator\nhostname gateway.invalid\nport 22\nidentityfile \(missingIdentityFile)\nproxyjump bastion.invalid\n")
        let result = await outcome(of: relayWithoutIdentity, authMode: .sessionAgent)
        XCTAssertEqual(result.refused, [.relayRefused])
    }

    func testExampleHostIsRefusedWithoutDumpingTheConfig() async {
        let resolver = GatedSSHResolver(dumps: [:])
        let connector = SSHConnector(resolver: resolver, localUser: "operator")
        var opened: [String] = []
        var refused: [SSHFailure] = []
        connector.begin(alias: "example-host.invalid", refuseTestHost: true, opened: { config, _ in opened.append(config.alias) }, refused: { failure, _ in refused.append(failure) })
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

private actor AliasDumpResolver: SSHConfigResolving {
    private let dumps: [String: SSHConfigDump]

    init(dumps: [String: SSHConfigDump]) {
        self.dumps = dumps
    }

    func dump(alias: String, invocation: SSHInvocation, agentSocket: String?) async throws -> SSHConfigDump {
        dumps[alias] ?? SSHConfigDump(stdout: "")
    }

    func dumpAPIKey(alias: String, profile: String, agentSocket: String?) async throws -> SSHConfigDump {
        dumps[alias] ?? SSHConfigDump(stdout: "")
    }
}

private actor GatedSSHResolver: SSHConfigResolving {
    private let dumps: [String: SSHConfigDump]
    private var gates: [String: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var started: [String] = []

    init(dumps: [String: SSHConfigDump]) {
        self.dumps = dumps
    }

    func dump(alias: String, invocation: SSHInvocation, agentSocket: String?) async throws -> SSHConfigDump {
        if invocation == .tunnel {
            started.append(alias)
            await withCheckedContinuation { continuation in
                gates[alias, default: []].append(continuation)
            }
        }
        return dumps[alias] ?? SSHConfigDump(stdout: "")
    }

    func dumpAPIKey(alias: String, profile: String, agentSocket: String?) async throws -> SSHConfigDump {
        dumps[alias] ?? SSHConfigDump(stdout: "")
    }

    func release(_ alias: String) {
        let waiting = gates[alias] ?? []
        gates[alias] = nil
        for waiter in waiting { waiter.resume() }
    }

    func releaseFirst(_ alias: String) {
        var waiting = gates[alias] ?? []
        guard !waiting.isEmpty else { return }
        let first = waiting.removeFirst()
        gates[alias] = waiting
        first.resume()
    }
}

private struct FailingSSHResolver: SSHConfigResolving {
    func dump(alias: String, invocation: SSHInvocation, agentSocket: String?) async throws -> SSHConfigDump {
        throw SSHFailure.unreadableConfig
    }

    func dumpAPIKey(alias: String, profile: String, agentSocket: String?) async throws -> SSHConfigDump {
        throw SSHFailure.unreadableConfig
    }
}

private actor ScriptedSSHResolver: SSHConfigResolving {
    private let dumps: [SSHInvocation: SSHConfigDump]
    private(set) var asked: [SSHInvocation] = []

    init(dumps: [SSHInvocation: SSHConfigDump]) {
        self.dumps = dumps
    }

    func dump(alias: String, invocation: SSHInvocation, agentSocket: String?) async throws -> SSHConfigDump {
        asked.append(invocation)
        return dumps[invocation] ?? SSHConfigDump(stdout: "")
    }

    func dumpAPIKey(alias: String, profile: String, agentSocket: String?) async throws -> SSHConfigDump {
        dumps[.profileList] ?? dumps[.tunnel] ?? SSHConfigDump(stdout: "")
    }
}

final class RealSshConfigTests: XCTestCase {
    private func preview(_ config: String, alias: String = "lab.invalid", files: [String: String] = [:]) async throws -> SSHConnectionPreview {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hb-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        for (name, text) in files.merging(["config": config], uniquingKeysWith: { $1 }) {
            try text.replacingOccurrences(of: "$DIR", with: directory.path).write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let dump = try await SystemSSHConfigResolver(configFile: directory.appendingPathComponent("config").path).dump(alias: alias, invocation: .tunnel)
        return SSHConfig.parse(dump, alias: alias, localUser: "operator")
    }

    private func failure(_ config: String, alias: String = "lab.invalid", files: [String: String] = [:]) async throws -> SSHFailure? {
        do {
            let next = try await preview(config, alias: alias, files: files)
            _ = try SSHConnectionPlanner.config(from: next, refuseTestHost: true)
            return nil
        } catch let failure as SSHFailure {
            return failure
        }
    }

    func testAMatchIncludeConfigResolvesTheAliasAndIsAccepted() async throws {
        let result = try await failure(
            "Include $DIR/inc.conf\n",
            files: [
                "inc.conf": """
                Match originalhost lab.invalid
                  User operator
                  Port 2222
                  Hostname gateway.example.invalid
                  IdentityFile /tmp/fake-id.invalid
                """,
            ]
        )
        XCTAssertNil(result)
        let next = try await preview(
            "Include $DIR/inc.conf\n",
            files: [
                "inc.conf": """
                Match originalhost lab.invalid
                  User operator
                  Port 2222
                  Hostname gateway.example.invalid
                  IdentityFile /tmp/fake-id.invalid
                """,
            ]
        )
        XCTAssertEqual(next.hostname, "gateway.example.invalid")
        XCTAssertEqual(next.user, "operator")
        XCTAssertEqual(next.port, 2222)
        XCTAssertFalse(next.identityPresent)
        XCTAssertNoThrow(try SSHConnectionPlanner.config(from: next, refuseTestHost: true))
    }

    func testMatchFormsThatSshAcceptsDoNotRefuseTheAlias() async throws {
        let forms = [
            "Match all\nUser operator\nHostname gateway.example.invalid\n",
            "Host lab.invalid\n  User operator\n  Hostname gateway.example.invalid\nMatch all\n",
            "Match originalhost lab.invalid\n  User operator\n  Hostname gateway.example.invalid\n",
        ]
        for config in forms {
            let result = try await failure(config)
            XCTAssertNil(result, config)
        }
    }

    func testAMatchBlockThatDoesNotApplyDoesNotRefuseANamedHost() async throws {
        let result = try await failure("Host lab.invalid\n  User operator\n  Hostname gateway.example.invalid\nMatch originalhost other.invalid\n  User y\n")
        XCTAssertNil(result)
    }

    func testANamedHostIsAccepted() async throws {
        let named = ["Host lab.invalid", "Host other lab.invalid", #"Host "lab.invalid""#, "Host *\nHost lab.invalid\n  User operator"]
        for config in named {
            let result = try await failure(config + "\n")
            XCTAssertNil(result, config)
        }
        let monalias = try await failure("Host monalias\n", alias: "monalias")
        XCTAssertNil(monalias)
    }

    func testAConfigThatSshCannotParseIsRefused() async throws {
        for config in ["Host \"lab\n", "Match\n", "Match exec\n", "Match bogus x\n", "Bogus yes\n", "Host lab.invalid\n  ProxyJump\n", "Host lab.invalid\n  Port\n"] {
            let result = try await failure(config)
            XCTAssertEqual(result, .unreadableConfig, config)
        }
    }

    func testAnAPIKeyDumpOfANamedHostIsAccepted() async throws {
        let result = try await apiKeyFailure(
            """
            Host lab.invalid
              User operator
              Hostname gateway.example.invalid
              IdentityFile /tmp/fake-id.invalid
            """
        )
        XCTAssertNil(result)
    }

    func testAnAPIKeyDumpThatAddsARelayIsRefused() async throws {
        let result = try await apiKeyFailure(
            """
            Host lab.invalid
              User operator
              Hostname gateway.example.invalid
              IdentityFile /tmp/fake-id.invalid
              ProxyJump bastion.invalid
            """
        )
        XCTAssertEqual(result, .relayRefused)
    }

    func testAnAPIKeyMatchCommandThatAddsARelayIsRefused() async throws {
        try await skipUnlessMatchCommand()
        let config = """
            Match command hermes*
              ProxyJump bastion.invalid
            Host lab.invalid
              User operator
              Hostname gateway.example.invalid
              IdentityFile /tmp/fake-id.invalid
            """
        let tunnel = try await failure(config)
        XCTAssertNil(tunnel)
        let key = try await apiKeyFailure(config)
        XCTAssertEqual(key, .relayRefused)
    }

    func testAnAPIKeyMatchCommandThatResolvesExampleHostIsRefused() async throws {
        try await skipUnlessMatchCommand()
        let config = """
            Match command hermes*
              Hostname example-host.invalid
            Host lab.invalid
              User operator
              Hostname gateway.example.invalid
              IdentityFile /tmp/fake-id.invalid
            """
        let tunnel = try await failure(config)
        XCTAssertNil(tunnel)
        let key = try await apiKeyFailure(config)
        XCTAssertEqual(key, .forbiddenHost)
    }

    func testAnAPIKeyMatchCommandThatChangesTheTunnelDestinationIsRefused() async throws {
        try await skipUnlessMatchCommand()
        let config = """
            Match command hermes*
              Hostname other.example.invalid
            Host lab.invalid
              User operator
              Hostname gateway.example.invalid
              IdentityFile /tmp/fake-id.invalid
            """
        let tunnel = try await preview(config)
        XCTAssertEqual(tunnel.hostname, "gateway.example.invalid")
        let planned = try SSHConnectionPlanner.config(from: tunnel, refuseTestHost: true)
        let key = try await apiKeyPreview(config)
        XCTAssertEqual(key.hostname, "other.example.invalid")
        XCTAssertThrowsError(try SSHConnectionPlanner.config(from: key, refuseTestHost: true, matching: planned)) {
            XCTAssertEqual($0 as? SSHFailure, .routeMismatch)
        }
    }

    private func apiKeyPreview(_ config: String, alias: String = "lab.invalid", profile: String = "hv-bot-a", files: [String: String] = [:]) async throws -> SSHConnectionPreview {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hb-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        for (name, text) in files.merging(["config": config], uniquingKeysWith: { $1 }) {
            try text.replacingOccurrences(of: "$DIR", with: directory.path).write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let dump = try await SystemSSHConfigResolver(configFile: directory.appendingPathComponent("config").path).dumpAPIKey(alias: alias, profile: profile)
        return SSHConfig.parse(dump, alias: alias, localUser: "operator")
    }

    private func apiKeyFailure(_ config: String, alias: String = "lab.invalid", profile: String = "hv-bot-a", files: [String: String] = [:]) async throws -> SSHFailure? {
        do {
            let next = try await apiKeyPreview(config, alias: alias, profile: profile, files: files)
            _ = try SSHConnectionPlanner.config(from: next, refuseTestHost: true)
            return nil
        } catch let failure as SSHFailure {
            return failure
        }
    }

    private func skipUnlessMatchCommand() async throws {
        let probe = try await apiKeyFailure(
            """
            Match command hermes*
              User operator
              Hostname gateway.example.invalid
            """
        )
        if probe == .unreadableConfig {
            throw XCTSkip("ssh does not support Match command")
        }
        XCTAssertNil(probe)
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

    private func knownDump(hostname: String) -> SSHConfigDump {
        SSHConfigDump(
            stdout: """
            user operator
            hostname \(hostname)
            port 22
            identityfile \(existingIdentityFile)
            proxyjump none
            """
        )
    }

    func testAnEmptySecondRequestOnAppModelNeverOpensTheFirstTunnel() async {
        let resolver = GatedSSHResolver(dumps: [
            "a.invalid": knownDump(hostname: "alpha.invalid"),
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

    func testRefreshPreviewDuringConnectKeepsEphemeralLaunchIdentity() async {
        let dump = knownDump(hostname: "gateway.invalid")
        let resolver = GatedSSHResolver(dumps: ["lab.invalid": dump])
        let environment = AppEnvironment.resolve(["HV_TEST_MODE": "1"], defaults: isolatedDefaults(), keychain: { InMemorySecretStore(apiKey: nil) })
        let model = AppModel(environment: environment, sshResolver: resolver)
        model.host = "lab.invalid"
        model.authMode = .ephemeralAgent
        model.authModeChosen = true
        model.keyCommandPath = "/tmp/example-key-command.invalid"
        model.connect()
        await eventually { await resolver.started == ["lab.invalid"] }
        model.authMode = .sessionAgent
        model.refreshPreview()
        await eventually { await resolver.started.count == 2 }
        await resolver.releaseFirst("lab.invalid")
        await eventually { model.launchClient?.authMode == .ephemeralAgent }
        XCTAssertEqual(model.launchClient?.authMode, .ephemeralAgent)
        XCTAssertEqual(model.preview?.identity, .agent)
        XCTAssertEqual(model.preview?.identity.label, "agent SSH")
        await resolver.release("lab.invalid")
        await eventually { model.preview?.identity == .agent && model.launchClient?.authMode == .ephemeralAgent }
        XCTAssertEqual(model.preview?.identity, .agent)
        XCTAssertEqual(model.preview?.identity.label, "agent SSH")
        XCTAssertEqual(model.launchClient?.authMode, .ephemeralAgent)
        XCTAssertNotEqual(model.preview?.identity, .file)
        await model.tunnel.stop()
    }

    func testConnectKeepsTheCapturedAuthModeWhenModeChangesDuringDump() async {
        let dump = SSHConfigDump(
            stdout: """
            user operator
            hostname 127.0.0.1
            port 1
            identityfile \(missingIdentityFile)
            proxyjump none
            """
        )
        let resolver = GatedSSHResolver(dumps: ["lab.invalid": dump])
        let environment = AppEnvironment.resolve(["HV_TEST_MODE": "1"], defaults: isolatedDefaults(), keychain: { InMemorySecretStore(apiKey: nil) })
        let model = AppModel(environment: environment, sshResolver: resolver)
        model.host = "lab.invalid"
        model.authMode = .sessionAgent
        model.connect()
        await eventually { await resolver.started == ["lab.invalid"] }
        model.authMode = .wrapper
        model.wrapperPath = "/tmp/example-wrapper.invalid"
        await resolver.release("lab.invalid")
        await eventually { model.preview?.identity == .file }
        XCTAssertEqual(model.preview?.identity, .file)
        await eventually {
            if case .failed = model.tunnel.state { true } else { false }
        }
        // le mode capturé est la session : sans identité, le connecteur refuse avant tout lancement ; le mode Exécutable (sans garde) donnerait missingWrapper
        if case .failed(let failure) = model.tunnel.state {
            XCTAssertEqual(failure, .noIdentity)
        } else {
            XCTFail("attendu un refus noIdentity, obtenu \(model.tunnel.state)")
        }
    }

    func testExampleHostOnAppModelNeverDumpsOrOpens() async {
        let resolver = GatedSSHResolver(dumps: [
            "example-host.invalid": knownDump(hostname: "example-host.invalid"),
        ])
        let environment = AppEnvironment.resolve(
            ["HV_TEST_MODE": "1", "HV_SSH_HOST": "example-host.invalid"],
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

    func testAnExternalIdentityAgentDefaultsToEphemeralModeUntilTheUserChooses() async {
        let dump = SSHConfigDump(
            stdout: """
            user operator
            hostname gateway.invalid
            port 22
            identityagent /tmp/fake-agent.invalid
            identityfile /tmp/fake-id.invalid
            proxyjump none
            """
        )
        let resolver = ScriptedSSHResolver(dumps: [.tunnel: dump])
        let environment = AppEnvironment.resolve(["HV_TEST_MODE": "1"], defaults: isolatedDefaults(), keychain: { InMemorySecretStore(apiKey: nil) })
        let model = AppModel(environment: environment, sshResolver: resolver)
        model.host = "lab.invalid"
        model.refreshPreview()
        await eventually { model.authMode == .ephemeralAgent }
        XCTAssertEqual(model.preview?.identity, .agent)
        model.authMode = .sessionAgent
        model.authModeChosen = true
        model.refreshPreview()
        await eventually { model.preview?.identity == .agent }
        XCTAssertEqual(model.preview?.identity, .agent)
        XCTAssertEqual(model.authMode, .sessionAgent)
    }

    func testChangingAliasDoesNotRecordAnAutomaticModeAsAUserChoice() async {
        let withAgent = SSHConfigDump(
            stdout: """
            user operator
            hostname gateway.invalid
            port 22
            identityagent /tmp/fake-agent.invalid
            identityfile /tmp/fake-id.invalid
            proxyjump none
            """
        )
        let resolver = AliasDumpResolver(dumps: [
            "agent.invalid": withAgent,
            "file.invalid": knownDump(hostname: "gateway.invalid"),
        ])
        let environment = AppEnvironment.resolve(["HV_TEST_MODE": "1"], defaults: isolatedDefaults(), keychain: { InMemorySecretStore(apiKey: nil) })
        let model = AppModel(environment: environment, sshResolver: resolver)
        model.host = "agent.invalid"
        model.refreshPreview()
        await eventually { model.authMode == .ephemeralAgent }
        XCTAssertFalse(model.authModeChosen)
        model.host = "file.invalid"
        model.refreshPreview()
        await eventually { model.authMode == .sessionAgent }
        XCTAssertFalse(model.authModeChosen)
        XCTAssertEqual(model.preview?.identity, .file)
    }

    func testAnEmptyKeyCommandDoesNotLoadAPrivateKeyWhenTheDumpNamesAnExternalIdentityAgent() async {
        let dump = SSHConfigDump(
            stdout: """
            user operator
            hostname gateway.invalid
            port 22
            identityagent /tmp/fake-agent.invalid
            identityfile /tmp/fake-id.invalid
            proxyjump none
            """
        )
        let resolver = ScriptedSSHResolver(dumps: [.tunnel: dump, .profileList: dump, .profileLocks: dump])
        let environment = AppEnvironment.resolve(["HV_TEST_MODE": "1"], defaults: isolatedDefaults(), keychain: { InMemorySecretStore(apiKey: nil) })
        let model = AppModel(environment: environment, sshResolver: resolver)
        model.host = "lab.invalid"
        model.authMode = .ephemeralAgent
        model.authModeChosen = true
        model.keyCommandPath = ""
        model.connect()
        await eventually {
            if case .failed = model.tunnel.state { true } else { false }
        }
        if case .failed(let failure) = model.tunnel.state {
            XCTAssertEqual(failure, .missingAgent)
        } else {
            XCTFail("\(model.tunnel.state)")
        }
        await model.tunnel.stop()
    }

    func testEphemeralPreviewOnAppModelShowsAgentNotFile() async {
        let dump = knownDump(hostname: "gateway.invalid")
        let resolver = ScriptedSSHResolver(dumps: [.tunnel: dump])
        let environment = AppEnvironment.resolve(["HV_TEST_MODE": "1"], defaults: isolatedDefaults(), keychain: { InMemorySecretStore(apiKey: nil) })
        let model = AppModel(environment: environment, sshResolver: resolver)
        model.host = "lab.invalid"
        model.authMode = .ephemeralAgent
        model.keyCommandPath = "/tmp/example-key-command.invalid"
        model.refreshPreview()
        await eventually { model.preview?.identity == .agent }
        XCTAssertEqual(model.preview?.identity.label, "agent SSH")
        XCTAssertTrue(model.preview?.identityPresent ?? false)
    }

    func testAnAliasWithANonDefaultPortShowsTheResolvedPortFromSSHConfig() async {
        let dump = SSHConfigDump(
            stdout: """
            user operator
            hostname example.invalid
            port 2200
            identityfile /tmp/fake-id.invalid
            proxyjump none
            """
        )
        let resolver = ScriptedSSHResolver(dumps: [.tunnel: dump])
        let environment = AppEnvironment.resolve(["HV_TEST_MODE": "1"], defaults: isolatedDefaults(), keychain: { InMemorySecretStore(apiKey: nil) })
        let model = AppModel(environment: environment, sshResolver: resolver)
        model.host = "example.invalid"
        model.refreshPreview()
        await eventually { model.displayedPort?.number == 2200 }
        XCTAssertEqual(model.displayedPort, SSHDisplayedPort.readOnly(resolvedPort: 2200))
        XCTAssertEqual(model.displayedPort?.settingsTitle, "Port (config SSH)")
        XCTAssertEqual(model.displayedPort?.statusText, "Port SSH 2200 (config SSH)")
        XCTAssertNil(try! SSHTunnelConfig(alias: "example.invalid", hostname: "example.invalid", user: "operator", sshPort: 2200, refuseTestHost: true).arguments(localPort: 1).firstIndex(of: "-p"))
    }

    func testAnAliasWithoutAPortShowsTheDumpDefaultFromSSHConfig() async {
        let dump = SSHConfigDump(
            stdout: """
            user operator
            hostname example.invalid
            identityfile /tmp/fake-id.invalid
            proxyjump none
            """
        )
        let resolver = ScriptedSSHResolver(dumps: [.tunnel: dump])
        let environment = AppEnvironment.resolve(["HV_TEST_MODE": "1"], defaults: isolatedDefaults(), keychain: { InMemorySecretStore(apiKey: nil) })
        let model = AppModel(environment: environment, sshResolver: resolver)
        model.host = "example.invalid"
        model.refreshPreview()
        await eventually { model.displayedPort?.fromSSHConfig == true }
        XCTAssertEqual(model.displayedPort, SSHDisplayedPort.readOnly(resolvedPort: SSHDisplayedPort.fallback))
        XCTAssertEqual(model.preview?.port, SSHDisplayedPort.fallback)
        XCTAssertEqual(model.displayedPort?.settingsTitle, "Port (config SSH)")
    }

    func testAFailedPortResolutionKeepsTheDefaultPortSetting() async {
        let environment = AppEnvironment.resolve(["HV_TEST_MODE": "1"], defaults: isolatedDefaults(), keychain: { InMemorySecretStore(apiKey: nil) })
        let model = AppModel(environment: environment, sshResolver: FailingSSHResolver())
        model.host = "example.invalid"
        model.refreshPreview()
        await eventually { model.displayedPort?.fromSSHConfig == false }
        XCTAssertEqual(model.displayedPort, SSHDisplayedPort.readOnly(resolvedPort: nil))
        XCTAssertNil(model.preview)
        XCTAssertEqual(model.displayedPort?.number, SSHDisplayedPort.fallback)
        XCTAssertEqual(model.displayedPort?.settingsTitle, "Port")
        XCTAssertEqual(model.displayedPort?.statusText, "Port SSH \(SSHDisplayedPort.fallback)")
    }

    func testConnectNeverReadsTheKeychainAndOpensWithTheAlias() async {
        let dumps = knownDump(hostname: "gateway.invalid")
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
        let args = try! SSHTunnelConfig(alias: "lab.invalid", hostname: "gateway.invalid", user: "operator", refuseTestHost: false).arguments(localPort: 1)
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
