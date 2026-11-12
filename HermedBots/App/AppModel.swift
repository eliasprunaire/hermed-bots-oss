import AppSettings
import HermesAdapter
import LoopGuard
import Observation
import SwiftUI
import UpdateCheck

private struct KeyFetchGenerationMismatch: Error {}

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
    var authModeChosen: Bool
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
        onRetryOpen: { [unowned self] in self.apiKeyFetches.reset() },
        unauthorizedOpenMessage: { [unowned self] profile in
            let holdsKey = (try? self.environment.secrets.resolvedAPIKey(profile: profile)) != nil
            return HermesAPIKey.unauthorizedMessage(profile: profile, holdsKey: holdsKey)
        },
        notifyPause: { [unowned self] cause in await self.notifyPause(cause) },
        pauseNotificationPending: environment.pauseNotificationLine
    )
    @ObservationIgnored lazy var profileLock = ProfileLock(
        connection: { [unowned self] in self.connection },
        read: { [unowned self] in try await self.readProfileLocks() }
    )
    @ObservationIgnored lazy var killSwitch = KillSwitch(
        endpoint: { [unowned self] in
            guard !self.isCheckingAPI, self.apiError == nil, self.capabilities != nil else { return nil }
            return self.apiURL.map { KillSwitchAPI(baseURL: $0, apiKey: nil, apiKeyForProfile: Self.boundAPIKey(self.environment.secrets)) }
        },
        connection: { [unowned self] in self.connection },
        runs: { [unowned self] in self.conversation.runningTurns },
        profiles: { [unowned self] in
            (self.bots.list.shown ?? []).map(\.id).filter { id in
                (try? self.environment.secrets.resolvedAPIKey(profile: id)) != nil
            }
        },
        confirmed: { [unowned self] in self.conversation.confirmStopped($0, status: $1, on: $2) },
        pending: { [unowned self] in self.conversation.startingTurns() },
        setStopping: { [unowned self] in self.conversation.stopInProgress = $0 }
    )
    private func startResumableRun(bot: String, text: String, session: String, model: String?, key: String) async throws -> String {
        guard let apiURL else { throw HermesError.unreachable(url: "", reason: "tunnel fermé") }
        do {
            return try await resumeAPI(apiURL).start(profile: bot, input: text, session: session, model: model, key: key)
        } catch {
            // l'envoi garde son refus d'origine : l'outil absent de l'hôte est dit par la bannière de version
            guard Self.isUnauthorized(error), (try? await fetchRemoteAPIKey(bot)) != nil else { throw error }
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
    private var pendingLaunch: SSHClientSettings?
    let updates: UpdateCheck
    private(set) var updateRender = 0
    #if DEBUG
    /// Mode test seulement : date de l'intérieur les blocages du fil principal, que la sonde de perf lit par `hd.perf.hang`
    let mainThreadWatch: MainThreadWatch?
    var testHangMilliseconds: Int { environment.testHangMilliseconds }
    #endif
    var isTestMode: Bool { environment.isTestMode }
    var testDarkAppearance: Bool { environment.testDarkAppearance }
    var testWindowSize: CGSize? { environment.testWindowSize }
    var isShotPreview: Bool { environment.testShotScene != nil }
    var compatibility: CompatibilityStatus {
        CompatibilityStatus.of(
            map: capabilities,
            checking: isCheckingAPI || conversation.isOpening,
            failure: tunnel.state.failureMessage ?? apiError ?? conversation.openError
        )
    }
    // de quoi lire la liste des profils par un second ssh : le même alias que le tunnel
    private var sshBackend: SystemSSHBackend?
    private var sshConfig: SSHTunnelConfig?
    private(set) var launchClient: SSHClientSettings?
    /// Une relecture SSH par profil et par 401/403, puis le message d'échec ; « Réessayer » la rouvre
    private let apiKeyFetches = APIKeyFetches()
    /// Une lecture en cours : un second refus du même profil attend la même lecture, il n'affiche pas un 401 pendant ce temps
    @ObservationIgnored private var keyFetching: Set<String> = []
    @ObservationIgnored private var keyFetchGeneration: [String: Int] = [:]
    @ObservationIgnored private var keyWaiters: [String: [(generation: Int, continuation: CheckedContinuation<String?, Error>)]] = [:]
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

    var updateState: UpdateCheckState {
        _ = updateRender
        return updates.state
    }

    func checkForUpdates() {
        UpdatesSettingsAction.perform(updates)
        updateRender += 1
    }

    func installUpdate() {
        UpdatesSettingsAction.install(updates)
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
            keyCommandPath: keyCommandPath.trimmingCharacters(in: .whitespacesAndNewlines),
            authModeChosen: authModeChosen
        ).save(to: environment.defaults)
    }

    func noteUserChoseAuthMode() {
        authModeChosen = true
        persistEndpoint()
        refreshPreview()
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
        // mode test : texte fixe, aucun UNUserNotificationCenter ; hors mode test : conserve l'injection
        self.notifyPause = environment.pauseNotifier(product: notifyPause)
        self.urlConfiguration = urlConfiguration
        self.environment = environment
        self.updates = updates
        self.sshResolver = sshResolver
        self.connector = SSHConnector(resolver: sshResolver)
        host = environment.ssh?.host ?? ""
        authMode = environment.ssh?.authMode ?? .sessionAgent
        authModeChosen = environment.ssh?.authModeChosen ?? false
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
        #if DEBUG
        if let name = environment.testShotScene, let scene = ShotScene(rawValue: name) {
            applyShot(scene)
        }
        #endif
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
        return HermesClient(baseURL: apiURL, timeout: 15, configuration: urlConfiguration, apiKeyForProfile: Self.boundAPIKey(environment.secrets))
    }

    private func resumeAPI(_ apiURL: URL) -> ResumeAPI {
        ResumeAPI(baseURL: apiURL, apiKey: nil, apiKeyForProfile: Self.boundAPIKey(environment.secrets))
    }

    /// Rien ne part sans la clé de ce profil : pas de Bearer d'un autre profil, pas de requête anonyme
    private static func boundAPIKey(_ secrets: SecretStore) -> @Sendable (String) throws -> String? {
        { profile in
            guard let key = try secrets.resolvedAPIKey(profile: profile) else {
                throw HermesError.apiKeyMissing(profile)
            }
            return key
        }
    }

    /// `list_profiles` : `hermes profile list` par un second canal ssh en lecture seule (décision S6)
    private func readProfiles() async throws -> [Profile] {
        #if DEBUG
        // Mode test avec table injectée : ne pas dépendre d'un `hermes profile list` SSH
        // (orb + tunnel inverse : la commande hôte échoue → bots.error + version « inconnue »).
        if let table = environment.testProfileTable {
            return try ProfileTable.parse(table)
        }
        #endif
        if let sshBackend, let sshConfig, case .open = tunnel.state {
            return try ProfileTable.parse(await sshBackend.readProfileList(sshConfig))
        }
        #if DEBUG
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
        throw SSHFailure.tunnelClosed
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
        previewGeneration += 1
        let client = capturedClientSettings()
        pendingLaunch = client
        connector.begin(
            alias: host,
            refuseTestHost: environment.refuseTestHost,
            authMode: client.authMode,
            keyCommandSet: !client.keyCommandPath.isEmpty,
            opened: { [weak self] config, preview in
            guard let self else { return }
            var launch = client
            if !self.authModeChosen {
                launch.authMode = SSHAuthModeChoice.selected(
                    userChose: false,
                    stored: client.authMode,
                    keyCommandSet: !client.keyCommandPath.isEmpty,
                    hasExternalIdentityAgent: preview.usesExternalIdentityAgent
                )
                self.authMode = launch.authMode
            }
            let shown = preview.matchingLaunch(mode: launch.authMode, keyCommandSet: !launch.keyCommandPath.isEmpty)
            self.previewGeneration += 1
            self.preview = shown
            self.displayedPort = .readOnly(resolvedPort: shown.port)
            self.openTunnel(config, client: launch)
            self.pendingLaunch = nil
        }, refused: { [weak self] failure, preview in
            guard let self else { return }
            self.pendingLaunch = nil
            self.previewGeneration += 1
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
        openTunnel(config, client: launchClient ?? capturedClientSettings())
    }

    private func resolvePreview(alias: String, id: Int, mode: SSHAuthMode, keyCommandSet: Bool) async {
        do {
            let dump = try await sshResolver.dump(alias: alias, invocation: .tunnel)
            let session = SSHConfig.parse(
                dump,
                alias: alias,
                localUser: NSUserName(),
                authSock: ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
            )
            guard id == previewGeneration else { return }
            if pendingLaunch != nil { return }
            let locked = launchClient
            if locked == nil, !authModeChosen {
                authMode = SSHAuthModeChoice.selected(
                    userChose: false,
                    stored: mode,
                    keyCommandSet: keyCommandSet,
                    hasExternalIdentityAgent: session.usesExternalIdentityAgent
                )
            }
            let overlayMode = SSHLaunchIdentity.overlayMode(picker: authMode, launch: locked?.authMode)
            let overlayKey = locked.map { !$0.keyCommandPath.isEmpty } ?? keyCommandSet
            let shown = session.matchingLaunch(mode: overlayMode, keyCommandSet: overlayKey)
            guard SSHLaunchIdentity.allows(shown.identity.launchKind, launch: locked?.authMode) else { return }
            preview = shown
            displayedPort = .readOnly(resolvedPort: session.port)
        } catch {
            guard id == previewGeneration else { return }
            if pendingLaunch != nil { return }
            preview = nil
            displayedPort = .readOnly(resolvedPort: nil)
        }
    }

    private func capturedClientSettings() -> SSHClientSettings {
        SSHClientSettings(
            authMode: authMode,
            wrapperPath: wrapperPath.trimmingCharacters(in: .whitespacesAndNewlines),
            keyCommandPath: keyCommandPath.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func openTunnel(_ config: SSHTunnelConfig, client: SSHClientSettings) {
        let backend = SystemSSHBackend(
            resolver: sshResolver,
            refuseTestHost: environment.refuseTestHost,
            client: client,
            keySource: ephemeralKeySource(client)
        )
        sshBackend = backend
        sshConfig = config
        launchClient = client
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
                case .toolNotFound(let message):
                    version = .unknown
                    apiError = message
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
        if (try? environment.secrets.resolvedAPIKey(profile: profile)) == nil {
            do {
                guard try await fetchRemoteAPIKey(profile) != nil else {
                    guard versionRequest == request, self.apiURL == baseURL, versionProfile == profile, !Task.isCancelled else { return }
                    version = .unknown
                    let message = HermesAPIKey.unauthorizedMessage(profile: profile, holdsKey: false)
                    refusal = (profile, message)
                    apiError = message
                    return
                }
            } catch {
                guard versionRequest == request, self.apiURL == baseURL, versionProfile == profile, !Task.isCancelled else { return }
                version = .unknown
                await handleAPIError(error, profile: profile)
                return
            }
            guard versionRequest == request, self.apiURL == baseURL, versionProfile == profile, !Task.isCancelled else { return }
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
        await acquireListedAPIKeys(except: profile)
        guard versionRequest == request, self.apiURL == baseURL, versionProfile == profile, !Task.isCancelled else { return }
        isCheckingAPI = false
        await checkCapabilities()
    }

    /// Les sondes du coupe-circuit portent sur chaque profil listé : leur clé est lue avant qu'une requête parte
    private func acquireListedAPIKeys(except current: String) async {
        for id in (bots.list.shown ?? []).map(\.id) where id != current {
            if (try? environment.secrets.resolvedAPIKey(profile: id)) == nil {
                _ = try? await fetchRemoteAPIKey(id)
            }
        }
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

    /// Saisie des réglages : la clé du profil va au Trousseau, remplace celle qui s'y trouve et sert aux requêtes suivantes
    /// La valeur ne revient jamais à l'écran ni dans un journal ; les espaces d'un collage sont retirés
    /// Une erreur de l'API après la saisie s'affiche dans la bannière, elle ne fait pas échouer l'enregistrement
    func storeAPIKey(_ key: String, profile: String) async throws {
        let profile = try HermesAPIKey.validate(profile)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: \.isNewline) else { throw ManualAPIKeyError.invalidKey }
        var secrets = environment.secrets
        try secrets.setAPIKey(key, profile: profile)
        environment.secrets = secrets
        // une clé neuve rouvre la lecture SSH, que la garde avait fermée pour ce refus
        apiKeyFetches.reset()
        bots.reload(profile)
        if apiError != nil { await recheckAPI() }
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
        HermesClient(baseURL: baseURL, timeout: 5, configuration: urlConfiguration, apiKeyForProfile: Self.boundAPIKey(environment.secrets))
    }

    private func readVersionRecovering(_ baseURL: URL, profile: String) async throws -> String? {
        do {
            return try await versionClient(baseURL).readVersion(profile: profile)
        } catch {
            guard Self.isUnauthorized(error), try await fetchRemoteAPIKey(profile) != nil else { throw error }
            return try await versionClient(baseURL).readVersion(profile: profile)
        }
    }

    /// `profile` est celui de la requête refusée, pas forcément celui qui est à l'écran
    /// L'erreur rouge n'apparaît qu'après les tentatives (0 → 400 ms → 1,2 s) et la relecture de clé
    func handleAPIError(_ error: Error, profile: String) async {
        if let failure = error as? APIKeyReadFailure { return showUnreadableKey(failure, profile: profile) }
        guard Self.isUnauthorized(error) else {
            apiError = Self.apiMessage(error)
            return
        }
        await recoverKey(of: profile)
    }

    private func recoverKey(of profile: String) async {
        isCheckingAPI = true
        apiError = nil
        let hadKey = (try? environment.secrets.resolvedAPIKey(profile: profile)) != nil
        do {
            if !hadKey {
                let obtained = try await ProfileOpenRetry.run { [self] in
                    do {
                        return try await fetchRemoteAPIKey(profile) != nil
                    } catch let failure as APIKeyReadFailure {
                        showUnreadableKey(failure, profile: profile)
                        return true
                    } catch SSHFailure.remoteToolNotFound {
                        apiError = SSHFailure.remoteToolNotFound.message
                        return true
                    } catch {
                        return false
                    }
                }
                isCheckingAPI = false
                if apiError != nil { return }
                if obtained {
                    guard (try? environment.secrets.resolvedAPIKey(profile: profile)) != nil else { return }
                    apiError = nil
                    await recheckAPI()
                    return
                }
            } else {
                isCheckingAPI = false
                if try await fetchRemoteAPIKey(profile) != nil {
                    apiError = nil
                    await recheckAPI()
                    return
                }
            }
        } catch is CancellationError {
            return
        } catch let failure as APIKeyReadFailure {
            isCheckingAPI = false
            showUnreadableKey(failure, profile: profile)
            return
        } catch {
            isCheckingAPI = false
            apiError = Self.apiMessage(error)
            return
        }
        isCheckingAPI = false
        if apiError != nil { return }
        let holdsKey = (try? environment.secrets.resolvedAPIKey(profile: profile)) != nil
        presentKeyFailure(HermesAPIKey.unauthorizedMessage(profile: profile, holdsKey: holdsKey), profile: profile)
    }

    /// Le bandeau en ligne du bot à l'écran porte déjà la panne de clé, pendant l'ouverture ou après les essais
    private func conversationPresentsKeyFailure(_ profile: String) -> Bool {
        conversation.botID == profile && (conversation.isOpening || conversation.openError != nil)
    }

    /// Une seule cause à l'écran : le chat unique en ouverture, sinon le bandeau global
    private func presentKeyFailure(_ message: String, profile: String) {
        refusal = (profile, message)
        if conversationPresentsKeyFailure(profile) {
            if conversation.openError != nil {
                conversation.presentOpenError(message, profile: profile)
            }
            apiError = nil
            return
        }
        apiError = message
    }

    /// La cause de la lecture ratée : introuvable, ou refusée si une clé est déjà détenue
    private func showUnreadableKey(_ failure: APIKeyReadFailure, profile: String) {
        let holdsKey = (try? environment.secrets.resolvedAPIKey(profile: profile)) != nil
        presentKeyFailure(failure.message(profile: profile, holdsKey: holdsKey), profile: profile)
    }

    /// Une lecture SSH par profil et par refus : le Trousseau est mis à jour, la valeur n'est pas journalisée
    /// Une saisie de clé ou un nouvel essai pendant la lecture la périme : sa valeur et sa panne sont jetées, la clé du Trousseau reste
    @discardableResult
    private func fetchRemoteAPIKey(_ profile: String) async throws -> String? {
        while true {
            if keyFetching.contains(profile) {
                let joinGeneration = apiKeyFetches.generation
                do {
                    return try await withCheckedThrowingContinuation { continuation in
                        keyWaiters[profile, default: []].append((joinGeneration, continuation))
                    }
                } catch is KeyFetchGenerationMismatch {
                    // une saisie ou un reset a périmé l'attente : reprendre la clé du Trousseau sans relancer SSH
                    if let held = try? environment.secrets.resolvedAPIKey(profile: profile) { return held }
                    continue
                } catch is CancellationError {
                    guard !Task.isCancelled else { throw CancellationError() }
                    if let held = try? environment.secrets.resolvedAPIKey(profile: profile) { return held }
                    continue
                }
            }
            let fetchGeneration = apiKeyFetches.generation
            keyFetching.insert(profile)
            keyFetchGeneration[profile] = fetchGeneration
            do {
                let key = try await performKeyFetch(profile)
                keyFetching.remove(profile)
                resumeKeyWaiters(for: profile, startedGeneration: fetchGeneration, result: .success(key))
                return key
            } catch {
                if error is CancellationError { apiKeyFetches.settle(profile) }
                keyFetching.remove(profile)
                resumeKeyWaiters(for: profile, startedGeneration: fetchGeneration, result: .failure(error))
                throw error
            }
        }
    }

    /// Les attentes partagées portent la génération de leur jointure : une saisie ou un reset pendant la lecture les relance
    private func resumeKeyWaiters(
        for profile: String,
        startedGeneration: Int,
        result: Result<String?, Error>
    ) {
        keyFetchGeneration.removeValue(forKey: profile)
        let waiters = keyWaiters.removeValue(forKey: profile) ?? []
        for (joinGeneration, continuation) in waiters {
            if joinGeneration == startedGeneration, joinGeneration == apiKeyFetches.generation {
                continuation.resume(with: result)
            } else {
                continuation.resume(throwing: KeyFetchGenerationMismatch())
            }
        }
    }

    private func performKeyFetch(_ profile: String) async throws -> String? {
        let source: @MainActor (String) async throws -> String?
        if let apiKeyReader {
            source = apiKeyReader
        } else if let sshBackend, let sshConfig, case .open = tunnel.state {
            source = { try await sshBackend.readAPIKey(sshConfig, profile: $0) }
        } else {
            return nil
        }
        let generation = apiKeyFetches.generation
        let read: @MainActor (String) async throws -> String? = { [apiKeyFetches] name in
            do {
                let value = try await source(name)
                return apiKeyFetches.generation == generation ? value : nil
            } catch {
                guard apiKeyFetches.generation == generation else { return nil }
                throw error
            }
        }
        var secrets = environment.secrets
        let key = try await apiKeyFetches.fetch(profile: profile, into: &secrets, read: read)
        // lecture périmée : la clé du Trousseau, saisie entre-temps, est celle que l'appelant reprend
        guard apiKeyFetches.generation == generation else { return try? environment.secrets.resolvedAPIKey(profile: profile) }
        if key != nil {
            environment.secrets = secrets
            // un dépli parti avant la clé attendait : on relit les fils de ce profil s'il est déplié
            bots.reload(profile)
            return key
        }
        if Task.isCancelled {
            apiKeyFetches.settle(profile)
            throw CancellationError()
        }
        return key
    }

    private static func isUnauthorized(_ error: Error) -> Bool {
        if case HermesError.apiKeyMissing = error { return true }
        if case HermesError.http(_, let status, _) = error, status == 401 || status == 403 { return true }
        return false
    }

    private func ephemeralKeySource(_ client: SSHClientSettings) -> (any SSHPrivateKeySource)? {
        guard client.authMode == .ephemeralAgent else { return nil }
        #if DEBUG
        if environment.isTestMode {
            let material = ProcessInfo.processInfo.environment["HV_TEST_SSH_KEY"] ?? ""
            if !material.isEmpty { return DataPrivateKeySource(data: Data(material.utf8)) }
        }
        #endif
        let command = client.keyCommandPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }
        return CommandPrivateKeySource(
            path: command,
            environment: ProcessInfo.processInfo.environment
        )
    }

    private static func apiMessage(_ error: Error) -> String {
        if case SSHFailure.remoteToolNotFound = error { return SSHFailure.remoteToolNotFound.message }
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

    #if DEBUG
    func applyShot(_ scene: ShotScene) {
        let bot = Bot(id: "shot-bot", name: "Bot de capture", model: "demo")
        let markdown: [ConversationMachine.Line] = [
            (1, .user, "Montre **gras**, une liste et un tableau."),
            (2, .assistant, """
            Le profil **default** produit plus de structure ; *tiny* reste plat.
            - Gras et listes rendus
            | Profil | Style |
            | --- | --- |
            | default | titres |
            ```
            func render()
            ```
            """),
        ]
        func showConversation(lines: [ConversationMachine.Line] = markdown, streaming: String? = nil, opening: Bool = false, error: String? = nil, tokens: Int? = nil) {
            bots.seedShown([bot])
            conversation.seedShot(bot: bot.id, session: "s-shot", lines: lines, streaming: streaming, isOpening: opening, openError: error, serverTokens: tokens)
        }
        switch scene {
        case .footerReady, .aboutReady:
            bots.seedShown([bot])
            capabilities = CapabilityMap(version: "0.22.2")
            version = .known("0.22.2")
            isCheckingAPI = false
        case .footerConnecting, .aboutConnecting:
            bots.seedShown([bot])
            isCheckingAPI = true
            version = .loading
        case .footerUntested, .aboutUntested:
            bots.seedShown([bot])
            capabilities = CapabilityMap(version: "0.99.0")
            version = .known("0.99.0")
        case .footerFailed, .aboutFailed:
            bots.seedShown([bot])
            apiError = HermesAPIKey.unauthorizedMessage(profile: bot.id, holdsKey: true)
            version = .unknown
        case .footerMissingKey:
            bots.seedShown([bot])
            apiError = HermesAPIKey.missingMessage(profile: bot.id)
            version = .unknown
        case .footerTunnel:
            bots.seedShown([bot])
            apiError = SSHFailure.tunnelClosed.message
            version = .unknown
        case .bannerDegraded:
            bots.seedShown([bot])
            capabilities = CapabilityMap(version: "0.22.2", states: [.listSessions: .disabled(message: "Fonction désactivée (la liste des fils passés) : capture.")])
            version = .known("0.22.2")
        case .connection:
            bots.seedShown([])
        case .error:
            bots.seedShown([bot])
            conversation.seedShot(bot: bot.id, session: nil, isOpening: false, openError: HermesAPIKey.unauthorizedMessage(profile: bot.id, holdsKey: true))
        case .emptyHome:
            bots.seedShown([])
        case .emptyConversation:
            showConversation(lines: [])
        case .markdown:
            showConversation()
        case .markdownStreaming:
            showConversation(streaming: "Début **gras encore ouvert")
        case .compacted:
            showConversation(tokens: 70_000)
        }
    }
    #endif
}

enum ManualAPIKeyError: Error, Equatable {
    /// Vide, ou sur plusieurs lignes : ce n'est pas une clé
    case invalidKey
}
