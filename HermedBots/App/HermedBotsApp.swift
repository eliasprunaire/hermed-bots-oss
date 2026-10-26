import AppSettings
import HermesAdapter
import Observation
import SwiftUI
import Sparkle
import UpdateCheck

@Observable
@MainActor
final class AppModel {
    enum Version: Equatable {
        case loading
        case known(String)
        case unknown
    }

    enum KeyState: Equatable {
        case unread
        case present
        case absent
        case unreadable
    }

    private(set) var apiError: String?
    private(set) var isCheckingAPI = false
    private(set) var capabilities: CapabilityMap?
    private var versionRequest = UUID()
    private var checkedBot: String?
    private(set) var version = Version.loading
    private(set) var keyState = KeyState.unread
    var host: String
    var user: String
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
        onAPIError: { [unowned self] in self.apiError = Self.apiMessage($0) },
        notifyPause: { await LoopPauseNotifications.shared.post(cause: $0) }
    )
    @ObservationIgnored lazy var profileLock = ProfileLock(
        connection: { [unowned self] in self.connection },
        read: { [unowned self] in try await self.readProfileLocks() }
    )
    @ObservationIgnored lazy var killSwitch = KillSwitch(
        endpoint: { [unowned self] in
            guard !self.isCheckingAPI, self.apiError == nil, self.capabilities != nil else { return nil }
            let secrets = self.environment.secrets
            return self.apiURL.map { KillSwitchAPI(baseURL: $0, apiKey: nil, apiKeyForProfile: { try secrets.apiKey(profile: $0) }) }
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
        let api = ResumeAPI(baseURL: apiURL, apiKey: try environment.secrets.apiKey(profile: bot))
        return try await api.start(profile: bot, input: text, session: session, model: model, key: key)
    }

    private var resumeStore: ResumeStore? {
        if !environment.isTestMode { return .applicationStore }
        guard let scope = environment.testResumeScope else { return nil }
        return ResumeStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("HermedBots-resume").appendingPathComponent(scope))
    }
    private var port: Int
    private var environment: AppEnvironment
    let updates: UpdateCheck
    private(set) var updateRender = 0
    #if DEBUG
    /// Mode test seulement : date de l'intérieur les blocages du fil principal, que la sonde de perf lit par `hd.perf.hang`
    let mainThreadWatch: MainThreadWatch?
    var testHangMilliseconds: Int { environment.testHangMilliseconds }
    #endif
    // de quoi lire la liste des profils par un second ssh : le même agent que le tunnel, la même cible
    private var sshBackend: SystemSSHBackend?
    private var sshConfig: SSHTunnelConfig?

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
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return }
        SSHEndpoint(host: trimmedHost, user: trimmedUser.isEmpty ? NSUserName() : trimmedUser, port: port).save(to: environment.defaults)
    }

    init(environment: AppEnvironment, updates: UpdateCheck = UpdateCheck(driver: NullUpdateDriver())) {
        self.environment = environment
        self.updates = updates
        host = environment.ssh?.host ?? ""
        user = environment.ssh?.user ?? NSUserName()
        port = environment.ssh?.port ?? 22
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
        return "\(sshConfig.user)@\(sshConfig.host):\(sshConfig.sshPort)"
    }

    private func hermesClient() -> HermesClient? {
        guard let apiURL else { return nil }
        let secrets = environment.secrets
        return HermesClient(baseURL: apiURL, timeout: 15, apiKeyForProfile: { try secrets.apiKey(profile: $0) })
    }

    func saveAPIKey(_ key: String, profile: String) throws {
        try environment.secrets.setAPIKey(key, profile: profile)
        checkedBot = nil
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

    /// Ouvre le tunnel vers l'hôte saisi ; un hôte refusé ou une clé absente s'affichent sans lancer ssh
    func connect() {
        let config: SSHTunnelConfig
        do {
            config = try SSHTunnelConfig(host: host, user: user, sshPort: port, refusePersoHermes: environment.isTestMode)
        } catch {
            tunnel.refuse(error as? SSHFailure ?? .invalidHost)
            return
        }
        persistEndpoint()
        openTunnel(config)
    }

    func reconnectAfterWake() {
        guard let config = sshConfig else { return }
        openTunnel(config)
    }

    private func openTunnel(_ config: SSHTunnelConfig) {
        let key: String
        do {
            guard let stored = try environment.secrets.sshPrivateKey(), !stored.isEmpty else {
                keyState = .absent
                tunnel.refuse(.keyMissing)
                return
            }
            key = stored
        } catch {
            keyState = .unreadable
            tunnel.refuse(.keyUnreadable)
            return
        }
        keyState = .present
        let backend = SystemSSHBackend(key: key, knownHostsPath: environment.isTestMode ? nil : Self.knownHostsPath())
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
        let secrets = environment.secrets
        let client = HermesClient(baseURL: baseURL, timeout: 5, apiKeyForProfile: { try secrets.apiKey(profile: $0) })
        do {
            let value = try await client.readVersion(profile: profile)
            guard versionRequest == request, self.apiURL == baseURL, versionProfile == profile, !Task.isCancelled else { return }
            version = value.map(Version.known) ?? .unknown
        } catch {
            guard versionRequest == request, self.apiURL == baseURL, versionProfile == profile, !Task.isCancelled else { return }
            version = .unknown
            apiError = Self.apiMessage(error)
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
            conversation.updateSupport(map, bot: bot)
        } catch {
            guard connection == target, versionRequest == request, versionProfile == bot else { return }
            apiError = Self.apiMessage(error)
        }
    }

    func retryAPI() async {
        guard !isCheckingAPI else { return }
        await refreshVersion()
        guard apiError == nil else { return }
        await bots.refresh()
        await checkCapabilities()
    }

    private static func apiMessage(_ error: Error) -> String {
        if case HermesError.apiKeyMissing(let profile) = error {
            return String(localized: "Clé API absente pour le profil \(profile). Enregistrez sa clé dans Connexion.")
        }
        if error is KeychainError {
            return String(localized: "La clé API du profil est illisible dans le Trousseau. Vérifiez son accès dans Connexion.")
        }
        if case HermesError.http(_, let status, _) = error, status == 401 || status == 403 {
            return String(localized: "La clé API est refusée. Vérifiez la clé avant de réessayer.")
        }
        return String(localized: "Hermes ne répond pas. Vérifiez la liaison puis réessayez.")
    }

    private static func knownHostsPath() -> String? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        let folder = support.appendingPathComponent("Hermed Bots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("known_hosts").path
    }
}

extension View {
    func accessibilityID(_ id: AccessibilityID) -> some View { accessibilityIdentifier(id.rawValue) }
}

extension AppModel.Version {
    var text: Text {
        switch self {
        case .loading: Text(verbatim: "…")
        case .known(let version): Text(verbatim: version)
        case .unknown: Text("inconnue")
        }
    }
}

struct ContentView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ErrorBanner(model: model)
            DegradedBanner(map: model.capabilities)
            StopAllButton(model: model.killSwitch).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            NavigationSplitView {
                BotListView(model: model.bots, profileLock: model.profileLock, selectedSession: model.conversation.sessionID, select: model.conversation.select(bot:), open: model.conversation.open(session:of:))
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260)
                    .safeAreaInset(edge: .bottom) {
                        HStack(spacing: 4) {
                            Text("Version de Hermes")
                            model.version.text.accessibilityID(.statusVersion)
                            Spacer()
                            SettingsLink {
                                Label("Réglages", systemImage: "gearshape").labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless)
                            .help("Réglages")
                            .accessibilityID(.connectionOpen)
                        }
                        .lineLimit(1)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(8)
                    }
            } detail: {
                if model.conversation.botID != nil {
                    ConversationView(model: model.conversation, killSwitch: model.killSwitch)
                } else {
                    Text("Aucun bot sélectionné").foregroundStyle(.secondary)
                }
            }
        }
        #if DEBUG
        .overlay(alignment: .bottomTrailing) {
            if let watch = model.mainThreadWatch {
                HangProbe(watch: watch, conversation: model.conversation, hangMilliseconds: model.testHangMilliseconds)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if model.mainThreadWatch != nil {
                ModelSwitchProbe(conversation: model.conversation)
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel(model.conversation.storedResumeState)
                    .accessibilityID(.resumeState)
            }
        }
        #endif
        .task(id: "\(model.apiURL?.absoluteString ?? "")#\((model.bots.list.shown ?? []).map(\.id).joined(separator: ","))") {
            while !Task.isCancelled {
                await model.killSwitch.checkSupport()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            model.reconnectAfterWake()
        }
        .task(id: "\(model.apiURL?.absoluteString ?? "")#\((model.bots.list.shown ?? []).map(\.id).joined(separator: ","))") {
            await model.conversation.restoreAvailable()
        }
        .task { await model.start() }
        .task(id: model.apiURL) {
            guard model.apiURL != nil else { return }
            await model.profileLock.run()
        }
        .task(id: "\(model.tunnel.state)#\(model.versionProfile ?? "")#\(model.bots.phase)") {
            await model.refreshVersion()
        }
        // la liste se relit tant qu'une adresse d'API existe ; une nouvelle adresse (tunnel rouvert) relance la lecture
        .task(id: model.apiURL) {
            guard model.apiURL != nil else { return }
            await model.bots.run()
        }
    }
}

#if DEBUG
/// Mode test seulement : un point sans pixel dont l'étiquette porte le rapport du chien de garde du fil principal
/// Avec `HV_HANG_MS`, il bloque aussi le fil principal au départ de chaque tour : c'est le contrôle positif de la sonde de perf
private struct HangProbe: View {
    let watch: MainThreadWatch
    let conversation: ConversationModel
    let hangMilliseconds: Int

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel(watch.report)
            .accessibilityID(.perfHang)
            .onChange(of: conversation.conversation.phase) { _, phase in
                if phase == .running, hangMilliseconds > 0 { Thread.sleep(forTimeInterval: Double(hangMilliseconds) / 1000) }
            }
    }
}

/// Mode test seulement : un point sans pixel dont l'étiquette liste, en ms, chaque durée du clic sur l'option de modèle (tel que l'app le reçoit) au modèle confirmé dans le sélecteur
private struct ModelSwitchProbe: View {
    let conversation: ConversationModel

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel(conversation.pickMilliseconds.map(String.init).joined(separator: ","))
            .accessibilityID(.perfModel)
            .onChange(of: conversation.shownModel) { conversation.selectorShowsModel() }
    }
}
#endif

@main
struct HermedBotsApp: App {
    #if !DEBUG
    private let sparkleDelegate: SparkleCycleDelegate
    private let updater: SPUStandardUpdaterController
    #endif
    @State private var model: AppModel

    init() {
        let environment = AppEnvironment.resolve(ProcessInfo.processInfo.environment)
        #if DEBUG
        let updates = UpdateCheck(driver: NullUpdateDriver())
        _model = State(initialValue: AppModel(environment: environment, updates: updates))
        #else
        let driver = SparkleUpdateDriver()
        let updates = UpdateCheck(driver: driver)
        let delegate = SparkleCycleDelegate(updates: updates)
        let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
        driver.attach(updater)
        updater.startUpdater()
        sparkleDelegate = delegate
        self.updater = updater
        _model = State(initialValue: AppModel(environment: environment, updates: updates))
        #endif
    }

    var body: some Scene {
        Window("Hermed Bots", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(SettingsCopy.checkForUpdates) { model.checkForUpdates() }
                    .disabled(!model.canCheckForUpdates)
            }
        }
        Settings {
            SettingsWindow(model: model)
        }
        .defaultSize(width: SettingsLayout.defaultWidth, height: SettingsLayout.defaultHeight)
    }
}
