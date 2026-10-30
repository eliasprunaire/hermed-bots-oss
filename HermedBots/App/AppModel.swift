import AppSettings
import HermesAdapter
import LoopGuard
import Observation
import SwiftUI
import UpdateCheck

@Observable
@MainActor
final class AppModel {
    enum Version: Equatable {
        case loading
        case known(String)
        case unknown
    }

    private(set) var apiError: String?
    private(set) var isCheckingAPI = false
    private(set) var capabilities: CapabilityMap?
    private var versionRequest = UUID()
    private var checkedBot: String?
    private(set) var version = Version.loading
    var host: String
    var authMode: SSHAuthMode
    var wrapperPath: String
    var keyCommandPath: String
    private(set) var preview: SSHConnectionPreview?
    /// Port montré en réglages et dans le statut : `ssh -G`, ou 22 si cette lecture échoue
    private(set) var displayedPort: SSHDisplayedPort?
    let tunnel = SSHTunnel()
    // paresseux : ses lectures appellent des méthodes de ce modèle, qui doit être construit en entier avant
    @ObservationIgnored lazy var bots = BotsModel(
        readProfiles: { [unowned self] in try await self.readProfiles() },
        client: { [unowned self] in self.hermesClient() },
        connection: { [unowned self] in self.connection }
    )
    // même raison : la conversation relit les fils d'un bot par `bots`, et lui demande les modèles des profils et celui de chaque fil
    @ObservationIgnored lazy var conversation = ConversationModel(
        client: { [unowned self] in self.hermesClient() },
        connection: { [unowned self] in self.connection },
        threadsChanged: { [unowned self] bot in self.bots.reload(bot) },
        bots: { [unowned self] in self.bots.list.shown ?? [] },
        listedThread: { [unowned self] bot, session in self.bots.listedThread(bot, session) },
        startedReads: { [unowned self] in self.bots.startedReads },
        approvalRetry: .seconds(1),
        profileLock: profileLock,
        resumeStore: resumeStore,
        startRun: { [unowned self] bot, text, session, model, key in
            try await self.startResumableRun(bot: bot, text: text, session: session, model: model, key: key)
        },
        onAPIRecovered: { [unowned self] in self.apiError = nil },
        onAPIError: { [unowned self] error, profile in Task { await self.handleAPIError(error, profile: profile) } },
        notifyPause: { [unowned self] cause in await self.notifyPause(cause) }
    )
    @ObservationIgnored lazy var profileLock = ProfileLock(
        connection: { [unowned self] in self.connection },
        read: { [unowned self] in try await self.readProfileLocks() }
    )
    @ObservationIgnored lazy var killSwitch = KillSwitch(
        endpoint: { [unowned self] in
            guard !self.isCheckingAPI, self.apiError == nil, self.capabilities != nil else { return nil }
            let secrets = self.environment.secrets
            return self.apiURL.map { KillSwitchAPI(baseURL: $0, apiKey: nil, apiKeyForProfile: { try secrets.resolvedAPIKey(profile: $0) }) }
        },
        connection: { [unowned self] in self.connection },
        runs: { [unowned self] in self.conversation.runningTurns },
        profiles: { [unowned self] in (self.bots.list.shown ?? []).map(\.id) },
        confirmed: { [unowned self] in self.conversation.confirmStopped($0, status: $1, on: $2) },
        pending: { [unowned self] in self.conversation.startingTurns() },
        setStopping: { [unowned self] in self.conversation.stopInProgress = $0 }
    )
    private func startResumableRun(bot: String, text: String, session: String, model: String?, key: String) async throws -> String {
        guard let apiURL else { throw HermesError.unreachable(url: "", reason: "tunnel fermé") }
        do {
            return try await resumeAPI(apiURL).start(profile: bot, input: text, session: session, model: model, key: key)
        } catch {
            guard Self.isUnauthorized(error), await fetchRemoteAPIKey(bot) != nil else { throw error }
            return try await resumeAPI(apiURL).start(profile: bot, input: text, session: session, model: model, key: key)
        }
    }

    private var resumeStore: ResumeStore? {
        if !environment.isTestMode { return .applicationStore }
        guard let scope = environment.testResumeScope else { return nil }
        return ResumeStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("HermedBots-resume").appendingPathComponent(scope))
    }
    private var environment: AppEnvironment
    private var sshResolver: any SSHConfigResolving
    private let connector: SSHConnector
    private var previewGeneration = 0
    let updates: UpdateCheck
    private(set) var updateRender = 0
    #if DEBUG
    /// Mode test seulement : date de l'intérieur les blocages du fil principal, que la sonde de perf lit par `hd.perf.hang`
    let mainThreadWatch: MainThreadWatch?
    var testHangMilliseconds: Int { environment.testHangMilliseconds }
    #endif
    // de quoi lire la liste des profils par un second ssh : le même alias que le tunnel
    private var sshBackend: SystemSSHBackend?
    private var sshConfig: SSHTunnelConfig?
    /// Une relecture SSH par profil et par 401/403, puis le message d'échec ; « Réessayer » la rouvre
    private let apiKeyFetches = APIKeyFetches()
    /// Le profil dont le refus affiche `apiError` : « Réessayer » relit sa clé, pas celle du profil à l'écran
    private var refusal: (profile: String, message: String)?
    /// Un test injecte la lecture de `API_SERVER_KEY` et la session HTTP ; l'app lit par SSH et par la session par défaut
    private let apiKeyReader: (@MainActor (String) async throws -> String?)?
    private let urlConfiguration: URLSessionConfiguration
    /// L'app injecte la notification macOS ; la cible de test n'embarque pas `UNUserNotificationCenter`
    private let notifyPause: @Sendable (LoopGuard.Cause) async -> String

    var canCheckForUpdates: Bool {
        _ = updateRender
        return updates.canCheck
    }

    func checkForUpdates() {
        UpdatesSettingsAction.perform(updates)
        updateRender += 1
    }

    func persistEndpoint() {
        guard !environment.isTestMode else { return }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return }
        SSHEndpoint(
            host: trimmedHost,
            authMode: authMode,
            wrapperPath: wrapperPath.trimmingCharacters(in: .whitespacesAndNewlines),
            keyCommandPath: keyCommandPath.trimmingCharacters(in: .whitespacesAndNewlines)
        ).save(to: environment.defaults)
    }

    init(
        environment: AppEnvironment,
        updates: UpdateCheck = UpdateCheck(driver: NullUpdateDriver()),
        sshResolver: any SSHConfigResolving = SystemSSHConfigResolver(),
        apiKeyReader: (@MainActor (String) async throws -> String?)? = nil,
        urlConfiguration: URLSessionConfiguration = .ephemeral,
        notifyPause: @escaping @Sendable (LoopGuard.Cause) async -> String = { _ in "Notification indisponible." }
    ) {
        self.apiKeyReader = apiKeyReader
        self.notifyPause = notifyPause
        self.urlConfiguration = urlConfiguration
        self.environment = environment
        self.updates = updates
        self.sshResolver = sshResolver
        self.connector = SSHConnector(resolver: sshResolver)
        host = environment.ssh?.host ?? ""
        authMode = environment.ssh?.authMode ?? .sessionAgent
        wrapperPath = environment.ssh?.wrapperPath ?? ""
        keyCommandPath = environment.ssh?.keyCommandPath ?? ""
        #if DEBUG
        if environment.isTestMode {
            let watch = MainThreadWatch()
            watch.start()
            mainThreadWatch = watch
        } else {
            mainThreadWatch = nil
        }
        #endif
        ProcessGroups.installTerminationHooks()
        updates.onChange = { [weak self] in
            Task { @MainActor in self?.updateRender += 1 }
        }
        refreshPreview()
    }

    /// L'adresse de l'API : le port du tunnel ouvert, ou l'adresse directe du mode test sans tunnel ; nil tant qu'aucune n'est joignable
    var apiURL: URL? {
        switch tunnel.state {
        case .open(let port): URL(string: "http://127.0.0.1:\(port)")
        case .idle: environment.baseURL
        case .opening, .reopening, .failed: nil
        }
    }

    /// L'hôte de Hermes où vivent les bots, les fils et le brouillon : la cible du tunnel ouvert par `connect()`, ou l'adresse directe du mode test sans tunnel
    /// Pas l'adresse de l'API : le port local du tunnel change à chaque ouverture, et peut ensuite servir un autre hôte
    private var connection: String {
        guard let sshConfig else { return environment.baseURL?.absoluteString ?? "" }
        return "\(sshConfig.user)@\(sshConfig.hostname):\(sshConfig.sshPort)"
    }

    private func hermesClient() -> HermesClient? {
        guard let apiURL else { return nil }
        let secrets = environment.secrets
        return HermesClient(baseURL: apiURL, timeout: 15, configuration: urlConfiguration, apiKeyForProfile: { try secrets.resolvedAPIKey(profile: $0) })
    }

    private func resumeAPI(_ apiURL: URL) -> ResumeAPI {
        let secrets = environment.secrets
        return ResumeAPI(baseURL: apiURL, apiKey: nil, apiKeyForProfile: { try secrets.resolvedAPIKey(profile: $0) })
    }

    /// `list_profiles` : `hermes profile list` par un second canal ssh en lecture seule (décision S6)
    private func readProfiles() async throws -> [Profile] {
        if let sshBackend, let sshConfig, case .open = tunnel.state {
            return try ProfileTable.parse(await sshBackend.readProfileList(sshConfig))
        }
        #if DEBUG
        if let table = environment.testProfileTable {
            return try ProfileTable.parse(table)
        }
        // mode test sans tunnel : le faux serveur sert la même table sur /_hv/profile-list (fixtures/README.md)
        if environment.ssh == nil, let base = environment.baseURL {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 5
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            let (data, _) = try await session.data(from: base.appendingPathComponent("_hv/profile-list"))
            return try ProfileTable.parse(String(decoding: data, as: UTF8.self))
        }
        #endif
        throw SSHFailure.unreachable("")
    }

    private func readProfileLocks() async throws -> Data {
        if let sshBackend, let sshConfig, case .open = tunnel.state {
            return try await sshBackend.readProfileLocks(sshConfig)
        }
        #if DEBUG
        if environment.ssh == nil, let base = environment.baseURL {
            // Les autres tests UI injectent une fixture libre ; ConcurrencyTests utilise le canal de détection simulé
            if !environment.testProfileLocks { return Data(#"{"held":[]}"#.utf8) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 3
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(from: base.appendingPathComponent("_hv/profile-locks"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SSHFailure.unreachable("détection Desktop indisponible") }
            return data
        }
        #endif
        throw SSHFailure.unreachable("tunnel fermé")
    }

    func start() async {
        if environment.ssh != nil { connect() }
    }

    /// Relit `ssh -G` pour l'alias saisi et met à jour les champs en lecture seule
    /// Un alias `example-host` en mode test n'appelle pas `ssh -G`
    func refreshPreview() {
        previewGeneration += 1
        let id = previewGeneration
        let alias = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty else {
            preview = nil
            displayedPort = nil
            return
        }
        if environment.refuseTestHost, SSHTunnelConfig.isForbiddenTestHost(alias) {
            preview = nil
            displayedPort = nil
            return
        }
        let mode = authMode
        let keyCommandSet = !keyCommandPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        Task { await resolvePreview(alias: alias, id: id, mode: mode, keyCommandSet: keyCommandSet) }
    }

    /// Ouvre le tunnel vers l'alias saisi ; un alias vide, invalide ou refusé invalide la génération en cours sans lancer ssh
    func connect() {
        apiKeyFetches.reset()
        persistEndpoint()
        connector.begin(
            alias: host,
            refuseTestHost: environment.refuseTestHost,
            authMode: authMode,
            keyCommandSet: !keyCommandPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            opened: { [weak self] config, preview in
            self?.preview = preview
            self?.displayedPort = .readOnly(resolvedPort: preview.port)
            self?.openTunnel(config)
        }, refused: { [weak self] failure, preview in
            guard let self else { return }
            if let preview {
                self.preview = preview
                self.displayedPort = .readOnly(resolvedPort: preview.port)
            } else {
                let alias = self.host.trimmingCharacters(in: .whitespacesAndNewlines)
                let forbidden = self.environment.refuseTestHost && SSHTunnelConfig.isForbiddenTestHost(alias)
                if !alias.isEmpty, !forbidden {
                    self.displayedPort = .readOnly(resolvedPort: nil)
                }
            }
            self.tunnel.refuse(failure)
        })
    }

    func reconnectAfterWake() {
        guard let config = sshConfig else { return }
        openTunnel(config)
    }

    private func resolvePreview(alias: String, id: Int, mode: SSHAuthMode, keyCommandSet: Bool) async {
        do {
            let dump = try await sshResolver.dump(alias: alias, invocation: .tunnel)
            let next = SSHConfig.parse(
                dump,
                alias: alias,
                localUser: NSUserName(),
                authSock: ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
            ).matchingLaunch(mode: mode, keyCommandSet: keyCommandSet)
            guard id == previewGeneration else { return }
            preview = next
            displayedPort = .readOnly(resolvedPort: next.port)
        } catch {
            guard id == previewGeneration else { return }
            preview = nil
            displayedPort = .readOnly(resolvedPort: nil)
        }
    }

    private func openTunnel(_ config: SSHTunnelConfig) {
        let backend = SystemSSHBackend(
            resolver: sshResolver,
            refuseTestHost: environment.refuseTestHost,
            client: SSHClientSettings(
                authMode: authMode,
                wrapperPath: wrapperPath.trimmingCharacters(in: .whitespacesAndNewlines),
                keyCommandPath: keyCommandPath.trimmingCharacters(in: .whitespacesAndNewlines)
            ),
            keySource: ephemeralKeySource()
        )
        sshBackend = backend
        sshConfig = config
        tunnel.start(config, backend: backend)
    }

    var versionProfile: String? { conversation.botID ?? bots.list.shown?.first?.id }

    /// Relit la version avec la route et la clé du profil affiché
    func refreshVersion() async {
        guard let baseURL = apiURL, let profile = versionProfile else {
            versionRequest = UUID()
            isCheckingAPI = false
            capabilities = nil
            checkedBot = nil
            apiError = nil
            switch tunnel.state {
            case .opening, .reopening: version = .loading
            case .failed: version = .unknown
            case .idle, .open:
                switch bots.phase {
                case .waiting, .loading: version = .loading
                case .ready: version = .unknown
                case .failed:
                    version = .unknown
                    apiError = String(localized: "Hermes ne répond pas. Vérifiez la liaison puis réessayez.")
                }
            }
            return
        }
        let request = UUID()
        versionRequest = request
        isCheckingAPI = true
        version = .loading
        apiError = nil
        capabilities = nil
        checkedBot = nil
        defer {
            if versionRequest == request { isCheckingAPI = false }
        }
        do {
            let value = try await readVersionRecovering(baseURL, profile: profile)
            guard versionRequest == request, self.apiURL == baseURL, versionProfile == profile, !Task.isCancelled else { return }
            version = value.map(Version.known) ?? .unknown
        } catch {
            guard versionRequest == request, self.apiURL == baseURL, versionProfile == profile, !Task.isCancelled else { return }
            version = .unknown
            await handleAPIError(error, profile: profile)
        }
        isCheckingAPI = false
        await checkCapabilities()
    }

    func checkCapabilities() async {
        guard !isCheckingAPI, apiError == nil, let bot = versionProfile,
              checkedBot != bot, let client = hermesClient() else { return }
        let target = connection
        let request = versionRequest
        checkedBot = bot
        do {
            let map = try await client.capabilities(profile: bot)
            guard connection == target, versionRequest == request, versionProfile == bot else { return }
            capabilities = map
            // `/health` est public : seules les sondes authentifiées prouvent que la clé est acceptée
            apiKeyFetches.settle(bot)
            conversation.updateSupport(map, bot: bot)
        } catch {
            guard connection == target, versionRequest == request, versionProfile == bot else { return }
            await handleAPIError(error, profile: bot)
        }
    }

    /// Bouton « Réessayer » : une lecture SSH échouée plus tôt peut repartir, pour le profil refusé
    func retryAPI() async {
        guard !isCheckingAPI else { return }
        apiKeyFetches.reset()
        if let refusal, apiError == refusal.message {
            await recoverKey(of: refusal.profile)
        } else {
            await recheckAPI()
        }
    }

    /// Sans rouvrir la garde : la relecture qui suit une clé récupérée ne boucle pas sur un 401 persistant
    private func recheckAPI() async {
        guard !isCheckingAPI else { return }
        await refreshVersion()
        guard apiError == nil else { return }
        await bots.refresh()
        await checkCapabilities()
    }

    private func versionClient(_ baseURL: URL) -> HermesClient {
        let secrets = environment.secrets
        return HermesClient(baseURL: baseURL, timeout: 5, configuration: urlConfiguration, apiKeyForProfile: { try secrets.resolvedAPIKey(profile: $0) })
    }

    private func readVersionRecovering(_ baseURL: URL, profile: String) async throws -> String? {
        do {
            return try await versionClient(baseURL).readVersion(profile: profile)
        } catch {
            guard Self.isUnauthorized(error), await fetchRemoteAPIKey(profile) != nil else { throw error }
            return try await versionClient(baseURL).readVersion(profile: profile)
        }
    }

    /// `profile` est celui de la requête refusée, pas forcément celui qui est à l'écran
    func handleAPIError(_ error: Error, profile: String) async {
        guard Self.isUnauthorized(error) else {
            apiError = Self.apiMessage(error)
            return
        }
        await recoverKey(of: profile)
    }

    private func recoverKey(of profile: String) async {
        if await fetchRemoteAPIKey(profile) != nil {
            apiError = nil
            await recheckAPI()
            return
        }
        let holdsKey = (try? environment.secrets.resolvedAPIKey(profile: profile)) != nil
        let message = HermesAPIKey.unauthorizedMessage(profile: profile, holdsKey: holdsKey)
        refusal = (profile, message)
        apiError = message
    }

    /// Une lecture SSH par profil et par refus : le Trousseau est mis à jour, la valeur n'est pas journalisée
    @discardableResult
    private func fetchRemoteAPIKey(_ profile: String) async -> String? {
        let read: @MainActor (String) async throws -> String?
        if let apiKeyReader {
            read = apiKeyReader
        } else if let sshBackend, let sshConfig, case .open = tunnel.state {
            read = { try await sshBackend.readAPIKey(sshConfig, profile: $0) }
        } else {
            return nil
        }
        var secrets = environment.secrets
        let key = await apiKeyFetches.fetch(profile: profile, into: &secrets, read: read)
        if key != nil {
            environment.secrets = secrets
            // un dépli parti avant la clé a gardé son 401 : on relit les fils de ce profil s'il est déplié
            bots.reload(profile)
        }
        return key
    }

    private static func isUnauthorized(_ error: Error) -> Bool {
        if case HermesError.apiKeyMissing = error { return true }
        if case HermesError.http(_, let status, _) = error, status == 401 || status == 403 { return true }
        return false
    }

    private func ephemeralKeySource() -> (any SSHPrivateKeySource)? {
        guard authMode == .ephemeralAgent else { return nil }
        #if DEBUG
        if environment.isTestMode {
            let material = ProcessInfo.processInfo.environment["HV_TEST_SSH_KEY"] ?? ""
            if !material.isEmpty { return DataPrivateKeySource(data: Data(material.utf8)) }
        }
        #endif
        return CommandPrivateKeySource(
            path: keyCommandPath.trimmingCharacters(in: .whitespacesAndNewlines),
            environment: ProcessInfo.processInfo.environment
        )
    }

    private static func apiMessage(_ error: Error) -> String {
        if case HermesError.apiKeyMissing(let name) = error {
            return HermesAPIKey.missingMessage(profile: name)
        }
        if error is KeychainError {
            return String(localized: "La clé API du profil est illisible dans le Trousseau.")
        }
        if case HermesError.http(_, let status, _) = error, status == 401 || status == 403 {
            return String(localized: "La clé API est refusée.")
        }
        return String(localized: "Hermes ne répond pas. Vérifiez la liaison puis réessayez.")
    }
}
