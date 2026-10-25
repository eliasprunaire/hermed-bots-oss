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
        proxyjump jump.invalid,hop2.invalid
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
        let preview = parse(includedDump, alias: "lab", existing: ["/tmp/fake-id.invalid-cert.pub"])
        XCTAssertFalse(preview.isUnknownAlias)
        XCTAssertEqual(preview.hostname, "gateway.invalid")
        XCTAssertEqual(preview.user, "operator")
        XCTAssertEqual(preview.port, 2222)
        XCTAssertEqual(preview.jumpCount, 2)
        XCTAssertEqual(preview.hopHosts, ["jump.invalid", "hop2.invalid"])
        XCTAssertEqual(preview.jumpLabel, "2 sauts")
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
        XCTAssertEqual(preview.jumpCount, 0)
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
        let preview = parse(dump, alias: "lab.invalid", existing: ["/tmp/fake-id.invalid.pub"])
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
        for text in [preview.user, preview.hostname, preview.jumpLabel, preview.identity.label, preview.identityPresentLabel, preview.identityPresentTitle] {
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

    func testAMatchHostWithOnlyStandardValuesIsKnownFromDashVvDebug() {
        let dump = defaultDump.replacingOccurrences(of: "unknown-alias.invalid", with: "match-defaults.invalid")
        let dashV = unmatchedDebug
        XCTAssertTrue(parse(dump, alias: "match-defaults.invalid", debug: dashV).isUnknownAlias)
        let dashVv = """
            debug2: checking match for 'host match-defaults.invalid' originally match-defaults.invalid
            debug3: match found
            debug1: Applying options for *
            """
        let preview = parse(dump, alias: "match-defaults.invalid", debug: dashVv)
        XCTAssertFalse(preview.isUnknownAlias)
        XCTAssertNoThrow(try SSHConnectionPlanner.config(from: preview, refusePersoHermes: true))
    }

    func testAPersoHermesProxyJumpIsRefusedInTestMode() {
        let dump = """
            user operator
            hostname gateway.invalid
            port 22
            identityfile /tmp/fake-id.invalid
            proxyjump jump.invalid,perso-hermes.invalid
            """
        let preview = parse(dump, alias: "lab.invalid")
        XCTAssertEqual(preview.hopHosts, ["jump.invalid", "perso-hermes.invalid"])
        XCTAssertThrowsError(try SSHConnectionPlanner.config(from: preview, refusePersoHermes: true)) {
            XCTAssertEqual($0 as? SSHFailure, .forbiddenHost)
        }
    }

    func testAPersoHermesProxyCommandIsRefusedInTestMode() {
        let dump = """
            user operator
            hostname gateway.invalid
            port 22
            identityfile /tmp/fake-id.invalid
            proxycommand ssh -W %h:%p perso-hermes.invalid
            """
        let preview = parse(dump, alias: "lab.invalid")
        XCTAssertEqual(preview.proxyCommand, "ssh -W %h:%p perso-hermes.invalid")
        XCTAssertThrowsError(try SSHConnectionPlanner.config(from: preview, refusePersoHermes: true)) {
            XCTAssertEqual($0 as? SSHFailure, .forbiddenHost)
        }
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
        XCTAssertEqual(await resolver.started, ["a.invalid"])
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
        XCTAssertEqual(await resolver.started, ["a.invalid"])
    }

    func testPersoHermesIsRefusedWithoutDumpingTheConfig() async {
        let resolver = GatedSSHResolver(dumps: [:])
        let connector = SSHConnector(resolver: resolver, localUser: "operator")
        var opened: [String] = []
        var refused: [SSHFailure] = []
        connector.begin(alias: "perso-hermes.invalid", refusePersoHermes: true, opened: { config, _ in opened.append(config.alias) }, refused: { failure, _ in refused.append(failure) })
        XCTAssertEqual(refused, [.forbiddenHost])
        XCTAssertEqual(opened, [])
        XCTAssertEqual(await resolver.started, [])
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

#if DEBUG
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
            stderr: "debug1: Applying options for \(alias)\n"
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
        XCTAssertEqual(await resolver.started, ["a.invalid"])
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
        XCTAssertEqual(await resolver.started, [])
        model.connect()
        XCTAssertEqual(await resolver.started, [])
        if case .failed(let failure) = model.tunnel.state {
            XCTAssertEqual(failure, .forbiddenHost)
        } else {
            XCTFail("\(model.tunnel.state)")
        }
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
#endif
