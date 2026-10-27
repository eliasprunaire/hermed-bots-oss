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
        XCTAssertNoThrow(try SSHConnectionPlanner.config(from: preview, refusePersoHermes: true))
    }

    func testSshGStdoutIsAcceptedEvenWhenOnlyDefaultIdentitiesAppear() {
        let preview = parse(defaultDump, alias: "unknown-alias.invalid")
        XCTAssertEqual(preview.hostname, "unknown-alias.invalid")
        XCTAssertEqual(preview.port, 22)
        XCTAssertFalse(preview.hasRelay)
        XCTAssertEqual(preview.identity, .file)
        XCTAssertFalse(preview.identityPresent)
        XCTAssertNoThrow(try SSHConnectionPlanner.config(from: preview, refusePersoHermes: true))
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
        XCTAssertNoThrow(try SSHConnectionPlanner.config(from: preview, refusePersoHermes: true))
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
        XCTAssertNoThrow(try SSHConnectionPlanner.config(from: preview, refusePersoHermes: true))
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
        let preview = parse(dump, alias: "lab.invalid")
        XCTAssertThrowsError(try SSHConnectionPlanner.config(from: preview, refusePersoHermes: true)) {
            XCTAssertEqual($0 as? SSHFailure, .forbiddenHost)
        }
        XCTAssertNoThrow(try SSHConnectionPlanner.config(from: preview, refusePersoHermes: false))
    }

    func testPersoHermesAliasIsRefusedInTestMode() {
        let dump = defaultDump.replacingOccurrences(of: "unknown-alias.invalid", with: "perso-hermes.invalid")
        let preview = parse(dump, alias: "perso-hermes.invalid")
        XCTAssertThrowsError(try SSHConnectionPlanner.config(from: preview, refusePersoHermes: true)) {
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
            XCTAssertNoThrow(try SSHConnectionPlanner.config(from: custom, refusePersoHermes: true), value)
        }
    }

    func testAnyProxyJumpOrProxyCommandIsRefusedInEveryMode() {
        let relays = [
            "proxyjump bastion.invalid",
            "proxyjump operator@bastion.invalid:2222,second.invalid",
            "proxyjump perso-hermes.invalid",
            "proxyjump -",
            "proxyjump ssh://jump-alias.invalid,second.invalid",
            "proxyjump blocked@jump-alias.invalid",
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
            let preview = parse(dump, alias: "lab.invalid")
            XCTAssertTrue(preview.hasRelay, relay)
            for refuse in [true, false] {
                XCTAssertThrowsError(try SSHConnectionPlanner.config(from: preview, refusePersoHermes: refuse), relay) {
                    XCTAssertEqual($0 as? SSHFailure, .relayRefused, relay)
                }
            }
        }
    }

    func testNoneIsNotARelay() {
        let preview = parse(includedDump, alias: "lab", existing: ["/tmp/fake-id.invalid-cert.pub"])
        XCTAssertFalse(preview.hasRelay)
        XCTAssertNoThrow(try SSHConnectionPlanner.config(from: preview, refusePersoHermes: false))
    }

    func testResolutionArgumentsAreDashGAndTheAlias() {
        XCTAssertEqual(SystemSSHConfigResolver.arguments(alias: "lab.invalid"), ["-G", "lab.invalid"])
        XCTAssertEqual(
            SystemSSHConfigResolver.arguments(alias: "lab.invalid", configFile: "/tmp/fake-ssh.invalid"),
            ["-G", "-F", "/tmp/fake-ssh.invalid", "lab.invalid"]
        )
        XCTAssertFalse(SystemSSHConfigResolver.arguments(alias: "lab.invalid").contains("-vv"))
    }
}

@MainActor
final class SSHConnectorTests: XCTestCase {
    private func knownDump(hostname: String) -> SSHConfigDump {
        SSHConfigDump(
            stdout: """
            user operator
            hostname \(hostname)
            port 22
            identityfile /tmp/fake-id.invalid
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
            "a.invalid": knownDump(hostname: "alpha.invalid"),
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
            "a.invalid": knownDump(hostname: "alpha.invalid"),
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

    func testAValidAliasOpensAfterOneDump() async {
        let resolver = ScriptedSSHResolver(dump: knownDump(hostname: "gateway.invalid"))
        let connector = SSHConnector(resolver: resolver, localUser: "operator")
        var opened: [String] = []
        var refused: [SSHFailure] = []
        connector.begin(alias: "lab.invalid", refusePersoHermes: true, opened: { config, _ in opened.append(config.alias) }, refused: { failure, _ in refused.append(failure) })
        await eventually { opened == ["lab.invalid"] }
        let asked = await resolver.asked
        XCTAssertEqual(asked, ["lab.invalid"])
        XCTAssertEqual(refused, [])
    }

    func testARelayInTheDumpIsRefusedInEveryMode() async {
        let dump = SSHConfigDump(
            stdout: "user operator\nhostname gateway.invalid\nport 22\nidentityfile /tmp/fake-id.invalid\nproxyjump bastion.invalid\n"
        )
        for refuse in [true, false] {
            let connector = SSHConnector(resolver: ScriptedSSHResolver(dump: dump), localUser: "operator")
            var opened: [String] = []
            var refused: [SSHFailure] = []
            connector.begin(alias: "lab.invalid", refusePersoHermes: refuse, opened: { config, _ in opened.append(config.alias) }, refused: { failure, _ in refused.append(failure) })
            await eventually { !refused.isEmpty || !opened.isEmpty }
            XCTAssertEqual(refused, [.relayRefused], "refuse=\(refuse)")
            XCTAssertEqual(opened, [], "refuse=\(refuse)")
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

private actor GatedSSHResolver: SSHConfigResolving {
    private let dumps: [String: SSHConfigDump]
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]
    private(set) var started: [String] = []

    init(dumps: [String: SSHConfigDump]) {
        self.dumps = dumps
    }

    func dump(alias: String) async throws -> SSHConfigDump {
        started.append(alias)
        await withCheckedContinuation { gates[alias] = $0 }
        return dumps[alias] ?? SSHConfigDump(stdout: "")
    }

    func release(_ alias: String) {
        gates[alias]?.resume()
        gates[alias] = nil
    }
}

private actor ScriptedSSHResolver: SSHConfigResolving {
    private let configured: SSHConfigDump
    private(set) var asked: [String] = []

    init(dump: SSHConfigDump) {
        configured = dump
    }

    func dump(alias: String) async throws -> SSHConfigDump {
        asked.append(alias)
        return configured
    }
}

/// Le vrai `/usr/bin/ssh -G -F <config>` : Match et Include viennent d'OpenSSH
final class RealSshConfigTests: XCTestCase {
    private func preview(_ config: String, alias: String = "lab.invalid", files: [String: String] = [:]) async throws -> SSHConnectionPreview {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hb-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        for (name, text) in files.merging(["config": config], uniquingKeysWith: { $1 }) {
            try text.replacingOccurrences(of: "$DIR", with: directory.path).write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let dump = try await SystemSSHConfigResolver(configFile: directory.appendingPathComponent("config").path).dump(alias: alias)
        return SSHConfig.parse(dump, alias: alias, localUser: "operator")
    }

    private func failure(_ config: String, alias: String = "lab.invalid", files: [String: String] = [:]) async throws -> SSHFailure? {
        do {
            let next = try await preview(config, alias: alias, files: files)
            _ = try SSHConnectionPlanner.config(from: next, refusePersoHermes: true)
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
        XCTAssertNoThrow(try SSHConnectionPlanner.config(from: next, refusePersoHermes: true))
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
            identityfile /tmp/fake-id.invalid
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

    func testPersoHermesOnAppModelNeverDumpsOrOpens() async {
        let resolver = GatedSSHResolver(dumps: [
            "perso-hermes.invalid": knownDump(hostname: "perso-hermes.invalid"),
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
        let resolver = ScriptedSSHResolver(dump: knownDump(hostname: "gateway.invalid"))
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
