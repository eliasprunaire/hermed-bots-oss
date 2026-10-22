import HermesAdapter
import LoopGuard
import Observation
import SwiftUI

/// La conversation ouverte : un bot, un fil, ses lignes et le brouillon
/// Les états et les transitions sont dans `ConversationMachine` ; ce modèle exécute ses effets et lui rend chaque résultat avec le fil qui l'a lancé
/// Un message part par `start_run` dans le fil du bot, la réponse arrive par `run_events` ; le chat de session ne rend aucun événement et répond HTTP 200 à un échec du fournisseur (S1)
///
/// Une machine et un brouillon par connexion (l'hôte de Hermes choisi dans l'app) : un fil, ses opérations et le texte tapé restent sur l'hôte où ils sont nés
/// Après un changement d'hôte, l'écran montre la machine et le brouillon du nouvel hôte ; ceux de l'ancien gardent leur état et le retrouvent au retour sur cet hôte
/// Une opération d'une connexion quittée n'envoie plus rien : le tunnel de l'ancien hôte est fermé, et son port local peut déjà servir le nouvel hôte
///
/// L'outil en cours et les approbations (HD-11) : le flux du tour donne l'outil que Hermes dit en cours et la demande qu'il attend ; la feuille montre la demande du fil à l'écran
/// Une décision part par `approve` une seule fois. Si la liaison est coupée, elle reste à l'écran et repart toutes les `approvalRetry` jusqu'à ce que Hermes la prenne, la refuse ou que le tour finisse
/// Une coupure garde le tour et son approbation ; la relecture reconstruit le tour et ignore les événements déjà observés
///
/// Le modèle du fil (HD-10) : `set_model` le verrouille sur la session ouverte, jamais sur le profil (S4) ; chaque run le porte, car `POST /v1/runs` ignore le verrou
/// Le sélecteur de modèle propose les modèles des bots actifs et celui du fil, tel que Hermes l'envoie
@Observable
@MainActor
final class ConversationModel {
    /// Ce qu'une route vaut pour un bot sur un hôte : `set_model` pour le sélecteur, `approve` pour la feuille
    enum RouteSupport: Equatable {
        /// Hermes n'a pas répondu à la sonde (pas encore lancée, ou en panne) : la fonction reste libre
        case unknown
        case available
        /// Le message dit quelle fonction manque et pourquoi ; seule cette fonction est désactivée
        case disabled(message: String)
    }

    private struct SupportKey: Hashable {
        let connection: String
        let bot: String
        let contract: Contract
    }

    private(set) var machines: [String: ConversationMachine] = [:]
    private struct RunKey: Hashable {
        let connection: String
        let thread: ConversationMachine.Key
    }
    private struct ProfileKey: Hashable {
        let connection: String
        let bot: String
    }
    private struct ReplayCursor {
        var sequence = -1
        var acceptsUpdates = true
        var disconnectedAt: TimeInterval?
        var replayed = false
        var truncated = false
    }
    private var replay: [RunKey: ReplayCursor] = [:]
    private var restoring: Set<ProfileKey> = []
    private let resumeStore: ResumeStore?
    private let startRun: (@MainActor (String, String, String, String?, String) async throws -> String)?
    private let onAPIRecovered: @MainActor () -> Void
    private var activeRuns: [String: [KillSwitch.Run: ConversationMachine.Key]] = [:]
    var stopInProgress = false
    var hasStartingTurn: Bool { machine.threads.values.contains { $0.step == .sending && $0.run == nil } }
    var runningTurns: [KillSwitch.Run] {
        Array(activeRuns[connection(), default: [:]].keys)
    }

    func confirmStopped(_ run: KillSwitch.Run, status: String) {
        let host = connection()
        guard let thread = activeRuns[host]?[run] else { return }
        activeRuns[host]?[run] = nil
        forget(RunKey(connection: host, thread: thread), run: run.id)
        guard let shown = machines[host]?.threads[thread], shown.run == run.id || shown.run == nil && shown.step == .ready else { return }
        let key = RunKey(connection: host, thread: thread)
        loopReports[key] = nil
        let end: TurnEnd
        switch status {
        case "cancelled": end = .cancelled
        case "completed": end = .completed
        case "failed": end = .failed
        default: end = .interrupted
        }
        apply(.stopped(key.thread, run: run.id, end: end), on: key.connection)
    }

    // shortcut: historique en mémoire, persister quand les seuils doivent survivre au redémarrage
    private var loopHistory: [ProfileKey: [LoopGuard.TurnStats]] = [:]
    private var loopEvents: [RunKey: [LoopGuard.Event]] = [:]
    private var loopReports: [RunKey: LoopGuard.Report] = [:]
    #if DEBUG
    private var pauseTimes: [RunKey: TimeInterval] = [:]
    var pauseDecisionTime: TimeInterval? { shownRun.flatMap { pauseTimes[$0] } }
    #endif
    private var notifications: [RunKey: String] = [:]
    private var shownRun: RunKey? { machine.screen.map { RunKey(connection: connection(), thread: $0) } }
    var pauseCause: LoopGuard.Cause? {
        guard let key = shownRun, case .pause(let cause, _) = loopReports[key]?.verdict else { return nil }
        return cause
    }
    var tokenSignal: LoopGuard.TokenSignal? { shownRun.flatMap { loopReports[$0]?.tokenSignal } }
    var loopThresholds: LoopGuard.Thresholds? { shownRun.flatMap { loopReports[$0]?.thresholds } }
    var pausedApproval: ConversationMachine.Approval? { pauseCause == nil ? nil : machine.shown.pendingApproval }
    var notificationStatus: String? { shownRun.flatMap { notifications[$0] } }

    private var drafts: [String: String] = [:]
    private var support: [SupportKey: RouteSupport] = [:]

    private let client: @MainActor () -> HermesClient?
    private let connection: @MainActor () -> String
    private let threadsChanged: @MainActor (String) -> Void
    private let bots: @MainActor () -> [Bot]
    private let listedThread: @MainActor (String, String) -> (model: String?, read: Int)?
    private let startedReads: @MainActor () -> Int
    private let onAPIError: @MainActor (Error) -> Void
    private let notifyPause: @Sendable (LoopGuard.Cause) async -> String
    private let approvalRetry: Duration
    let profileLock: ProfileLock?

    /// `connection` nomme l'hôte de Hermes ; sans lui, l'adresse du client le nomme, ce qui ne vaut que pour un client à adresse fixe : le port local du tunnel change à chaque ouverture
    /// `threadsChanged` reçoit le bot dont la liste des fils a bougé (fil créé, tour fini) sur l'hôte courant
    /// `bots` donne les profils actifs, dont le modèle est celui d'un fil sans choix ; `listedThread` donne le modèle que la liste des fils écrit pour un fil (bot, fil) et le numéro de la lecture qui le donne
    /// `startedReads` donne le numéro de la dernière lecture de la liste des fils partie : la confirmation d'un choix le retient
    /// `approvalRetry` est l'attente entre deux essais d'une décision que la liaison coupée n'a pas laissée partir
    init(
        client: @escaping @MainActor () -> HermesClient?,
        connection: (@MainActor () -> String)? = nil,
        threadsChanged: @escaping @MainActor (String) -> Void = { _ in },
        bots: @escaping @MainActor () -> [Bot] = { [] },
        listedThread: @escaping @MainActor (String, String) -> (model: String?, read: Int)? = { _, _ in nil },
        startedReads: @escaping @MainActor () -> Int = { 0 },
        approvalRetry: Duration = .seconds(1),
        profileLock: ProfileLock? = nil,
        resumeStore: ResumeStore? = nil,
        startRun: (@MainActor (String, String, String, String?, String) async throws -> String)? = nil,
        onAPIRecovered: @escaping @MainActor () -> Void = {},
        onAPIError: @escaping @MainActor (Error) -> Void = { _ in },
        notifyPause: @escaping @Sendable (LoopGuard.Cause) async -> String = { _ in "Notification indisponible." }
    ) {
        self.resumeStore = resumeStore
        self.startRun = startRun
        self.onAPIRecovered = onAPIRecovered
        self.client = client
        self.connection = connection ?? { client()?.baseURL.absoluteString ?? "" }
        self.threadsChanged = threadsChanged
        self.bots = bots
        self.listedThread = listedThread
        self.startedReads = startedReads
        self.approvalRetry = approvalRetry
        self.profileLock = profileLock
        self.notifyPause = notifyPause
        self.onAPIError = onAPIError
    }

    #if DEBUG
    var storedResumeState: String {
        guard let botID, let resumeStore else { return "[]" }
        do { return String(decoding: try resumeStore.data(connection: connection(), bot: botID), as: UTF8.self) }
        catch { return "Lecture du fichier de reprise impossible." }
    }
    #endif

    /// La machine de l'hôte courant
    var machine: ConversationMachine { machines[connection()] ?? ConversationMachine() }
    var botID: String? { machine.screen?.bot }
    /// nil tant que le fil à l'écran n'existe pas sur Hermes : le premier envoi, ou « Nouvelle session », le crée
    var sessionID: String? { machine.screen?.session }
    var conversation: Conversation { machine.shown.conversation }
    /// Le transcript du fil à l'écran est en cours de lecture
    var isLoading: Bool { machine.shown.step == .loading }
    /// L'écran dit « Le bot répond… » tant qu'un tour tourne dans le fil à l'écran
    var isBusy: Bool { profileLockReason == nil && pauseCause == nil && machine.shown.step == .sending }
    var canSend: Bool { !stopInProgress && profileLockReason == nil && pauseCause == nil && machine.canSend(draft) }

    var profileLockReason: String? { botID.flatMap { profileLock?.state($0).reason } }

    private func permits(_ key: ConversationMachine.Key, on host: String, queueOnUnknown: Bool = false) async -> Bool {
        guard let profileLock, host == connection() else { return true }
        guard await profileLock.permits(key.bot, on: host) else {
            // Les effets gardent leur traitement d'une liaison quittée, dont l'approbation mise en attente
            guard host == connection() else { return true }
            if queueOnUnknown, profileLock.state(key.bot, on: host) == .unknown { return false }
            let reason = profileLock.state(key.bot, on: host).reason ?? String(localized: "La détection du profil a changé. Réessayez.")
            apply(.modelFailed(key, reason), on: host)
            apply(.failed(key, reason), on: host)
            return false
        }
        return true
    }

    // MARK: le modèle du fil à l'écran

    /// Le modèle que Hermes donne par défaut au bot de l'écran : la colonne Model de `hermes profile list`
    private var profileModel: String? { botID.flatMap { id in bots().first { $0.id == id }?.model } }
    /// Le modèle du fil à l'écran : le choix fait avant la création du fil, sinon celui que son verrou donne, sinon celui du profil ; nil quand aucun n'est connu
    var shownModel: String? { machine.shown.shownModel ?? profileModel }
    /// Un choix attend la confirmation de Hermes : le modèle affiché ne change pas encore
    var isModelPending: Bool { machine.shown.pendingModel != nil }
    var modelError: String? { machine.shown.modelError }
    /// Les modèles des profils actifs, plus celui du fil, qui peut être un nom que l'app ne connaît pas
    var modelOptions: [String] { Set(bots().compactMap(\.model) + [shownModel].compactMap { $0 }).sorted() }
    var modelSupport: RouteSupport { supportOf(.setModel) }
    private func supportOf(_ contract: Contract) -> RouteSupport {
        botID.flatMap { support[SupportKey(connection: connection(), bot: $0, contract: contract)] } ?? .unknown
    }
    /// Change avec le bot et l'hôte : la vue relance la sonde à chaque changement
    var modelSupportTarget: String? { botID.map { "\(connection())#\($0)" } }
    /// Le brouillon de l'hôte courant : un texte tapé pour un hôte ne part jamais dans un fil d'un autre hôte
    var draft: String {
        get { drafts[connection(), default: ""] }
        set { drafts[connection()] = newValue }
    }

    // MARK: l'outil en cours et les approbations

    /// L'outil que Hermes dit en cours dans le fil à l'écran
    var currentTool: String? { machine.shown.tool }
    /// La demande du fil à l'écran qui attend l'utilisateur ou sa décision : la feuille la montre
    var approval: ConversationMachine.Approval? { pauseCause == nil ? machine.shown.pendingApproval : nil }
    /// Le bot attend l'utilisateur : la demande est affichée et personne n'a encore répondu
    var isWaitingForUser: Bool { approval.map { $0.decision == nil } ?? false }
    var approveSupport: RouteSupport { supportOf(.approve) }

    /// Répond à la demande du fil à l'écran ; rien ne part sans demande, pour une décision déjà prise, ni quand `approve` est désactivée
    func answer(_ decision: ConversationMachine.Decision) {
        guard !stopInProgress, profileLockReason == nil else { return }
        if case .disabled = approveSupport { return }
        apply(.answer(decision), on: connection())
    }

    // MARK: l'utilisateur

    /// Choisit un bot : son fil pas encore créé, que le premier envoi crée
    func select(bot id: String) {
        if botID != id { draft = "" }
        apply(.select(bot: id), on: connection())
        let host = connection()
        Task { await restore(bot: id, on: host) }
    }

    /// Rouvre un fil passé avec son transcript ; le fil prend le modèle que la liste des fils lui donne quand la lecture est partie après la confirmation de son dernier choix
    func open(session: String, of bot: String) {
        guard profileLock?.state(bot) == nil || profileLock?.state(bot) == .free else { return select(bot: bot) }
        if botID != bot { draft = "" }
        let listed = listedThread(bot, session)
        apply(.open(session: session, bot: bot, model: listed?.model, read: listed?.read ?? 0), on: connection())
    }

    /// Choisit le modèle du fil à l'écran : `set_model` sur cette session seulement, jamais le modèle du profil
    /// Rien ne part pour le modèle déjà montré, pour un choix en vol, ni quand `set_model` est désactivée
    func pick(model: String) {
        guard profileLockReason == nil, !model.isEmpty, model != shownModel else { return }
        if case .disabled = modelSupport { return }
        #if DEBUG
        if !isModelPending { pickStart = (model, .now) }
        #endif
        apply(.pickModel(model), on: connection())
    }

    #if DEBUG
    /// Mode test seulement, pour la sonde de perf de HD-10 : le clic sur l'option tel que l'app le reçoit (`pick`), et la durée jusqu'au modèle confirmé dans le sélecteur
    private var pickStart: (model: String, at: ContinuousClock.Instant)?
    private(set) var pickMilliseconds: [Int] = []

    /// La vue de sonde l'appelle quand le sélecteur change de modèle
    func selectorShowsModel() {
        guard let start = pickStart, start.model == shownModel else { return }
        let elapsed = ContinuousClock.now - start.at
        pickMilliseconds.append(Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000))
        pickStart = nil
    }
    #endif

    /// Sonde `set_model` seul, une fois par bot et par hôte : une route retirée désactive le sélecteur, pas le reste
    /// Une panne ne décide rien : le sélecteur reste libre et la sonde suivante redemande
    func checkModelSupport() async {
        guard let bot = botID else { return }
        await probeSupport(.setModel, bot: bot, on: connection(), force: false)
    }

    /// Le premier appel d'un double clic ouvre le tour, le second le trouve ouvert et ne fait rien
    func send() {
        guard canSend else { return }
        let text = draft
        draft = ""
        apply(.send(text), on: connection())
    }

    /// « Nouvelle session » : un fil vide chez Hermes (`new_session`, S4), jamais `/reset` ; l'ancien fil reste dans la liste des fils passés
    func newSession() {
        guard !stopInProgress, profileLockReason == nil else { return }
        apply(.newSession, on: connection())
    }

    func closePausedThread() {
        guard let key = shownRun, pauseCause != nil else { return }
        if let run = machine.shown.run { forget(key, run: run) }
        apply(.failed(key.thread, "Observation fermée localement. Hermes peut continuer sur le serveur."), on: key.connection)
        newSession()
    }

    // MARK: les effets

    /// Chaque effet garde la connexion de la machine qui l'a rendu, et lui rend son résultat
    private func apply(_ event: ConversationMachine.Event, on connection: String) {
        for effect in machines[connection, default: ConversationMachine()].handle(event) {
            switch effect {
            case .threadsChanged(let bot): if connection == self.connection() { threadsChanged(bot) }
            case .load(let key): Task { await load(key, on: connection) }
            case .create(let key, let message): Task { await create(key, message: message, on: connection) }
            case .run(let key, let message, let model): Task { await run(key, message: message, model: model, on: connection) }
            case .setModel(let key, let model): Task { await setModel(key, model: model, on: connection) }
            case .reread(let key, let turn): Task { await reread(key, turn: turn, on: connection) }
            case .approve(let key, let run, let request, let decision): Task { await approve(key, run: run, request: request, decision: decision, on: connection) }
            case .probeApprove(let key): Task { await probeSupport(.approve, bot: key.bot, on: connection, force: false) }
            }
        }
    }

    /// Le client de l'hôte courant, seulement si l'opération est née sur cet hôte
    private func client(_ connection: String) -> HermesClient? {
        connection == self.connection() ? client() : nil
    }

    private func load(_ key: ConversationMachine.Key, on connection: String) async {
        guard await permits(key, on: connection) else { return }
        guard let session = key.session else { return }
        guard let client = client(connection) else { return apply(.failed(key, Self.unreachable), on: connection) }
        do {
            apply(.loaded(key, Self.lines(try await client.messages(profile: key.bot, session: session))), on: connection)
        } catch {
            if connection == self.connection() { reportAPIError(error) }
            apply(.failed(key, Self.message(error)), on: connection)
        }
    }

    private func create(_ key: ConversationMachine.Key, message: String?, on connection: String) async {
        guard await permits(key, on: connection) else { return }
        guard let client = client(connection) else { return apply(.failed(key, Self.unreachable), on: connection) }
        do {
            apply(.created(key, session: try await client.newSession(profile: key.bot).id, message: message), on: connection)
        } catch {
            if connection == self.connection() { reportAPIError(error) }
            apply(.failed(key, Self.message(error)), on: connection)
        }
    }

    func restoreAvailable() async {
        let host = connection()
        for bot in bots() { await restore(bot: bot.id, on: host) }
    }

    private func restore(bot: String, on host: String) async {
        let profile = ProfileKey(connection: host, bot: bot)
        guard !restoring.contains(profile), let resumeStore else { return }
        restoring.insert(profile)
        defer { restoring.remove(profile) }
        do {
            for record in try resumeStore.records(connection: host, bot: bot) {
                let key = ConversationMachine.Key(bot: bot, thread: .session(record.session))
                guard machines[host]?.threads[key] == nil else { continue }
                guard host == connection(), let client = client(host), await permits(key, on: host) else { return }
                let lines = Self.lines(try await client.messages(profile: bot, session: record.session))
                guard host == connection(), machines[host]?.threads[key] == nil else { continue }
                apply(.restored(key, run: record.run, lines: lines), on: host)
                Task { await follow(key, run: record.run, on: host, restoring: true) }
            }
        } catch { if host == connection() { onAPIError(error) } }
    }

    private func run(_ key: ConversationMachine.Key, message: String, model: String?, on connection: String) async {
        guard await permits(key, on: connection), let session = key.session else { return }
        let admission = RunAdmission()
        do {
            let run: String
            if let startRun {
                while true {
                    guard admission.permitsRetry() else {
                        throw HermesError.decoding(contract: "start_run", detail: "Accusé absent. La clé expire. Aucun nouvel envoi automatique.")
                    }
                    guard connection == self.connection() else { throw HermesError.unreachable(url: "", reason: Self.unreachable) }
                    do {
                        run = try await startRun(key.bot, message, session, model, admission.key)
                        break
                    } catch {
                        guard Self.isLinkFailure(error) else { throw error }
                        reportAPIError(error)
                        try await Task.sleep(for: approvalRetry)
                    }
                }
            } else {
                guard let client = client(connection) else { throw HermesError.unreachable(url: "", reason: Self.unreachable) }
                run = try await client.startRun(profile: key.bot, input: message, session: session, model: model)
            }
            apply(.runStarted(key, run: run), on: connection)
            do { try resumeStore?.save(.init(session: session, run: run), connection: connection, bot: key.bot) }
            catch { if connection == self.connection() { onAPIError(error) } }
            guard connection == self.connection() else { return apply(.failed(key, Self.unreachable), on: connection) }
            await follow(key, run: run, on: connection)
        } catch {
            if connection == self.connection() { reportAPIError(error) }
            apply(.failed(key, Self.message(error)), on: connection)
        }
    }

    private func follow(_ key: ConversationMachine.Key, run: String, on connection: String, restoring: Bool = false) async {
        let runKey = RunKey(connection: connection, thread: key)
        let stopTarget = KillSwitch.Run(profile: key.bot, id: run)
        activeRuns[connection, default: [:]][stopTarget] = key
        replay[runKey] = ReplayCursor(replayed: restoring)
        loopEvents[runKey] = []
        loopReports[runKey] = nil
        notifications[runKey] = nil
        let silenceWatch = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard machines[connection]?.threads[key]?.run == run else { return }
                if replay[runKey]?.disconnectedAt == nil, !evaluateLoop(runKey) { return }
            }
        }
        defer { silenceWatch.cancel(); replay[runKey] = nil }
        var closedWithoutProgress = 0
        while machines[connection]?.threads[key]?.run == run {
            do {
                if profileLock?.state(key.bot, on: connection) == .unknown {
                    if replay[runKey]?.disconnectedAt == nil { replay[runKey]?.disconnectedAt = Date().timeIntervalSince1970 }
                    try await Task.sleep(for: approvalRetry)
                    continue
                }
                guard let client = client(connection) else { throw HermesError.unreachable(url: "", reason: Self.unreachable) }
                let sequence = replay[runKey]?.sequence
                let turn = try await client.readTurn(profile: key.bot, run: run, onEvent: { [weak self] data in
                    await self?.observeReplay(data, key: runKey, run: run) ?? false
                }) { [weak self] turn in
                    await self?.updateReplay(turn, key: runKey, run: run)
                }
                guard machines[connection]?.threads[key]?.run == run else { return }
                if replay[runKey]?.truncated == true {
                    throw HermesError.decoding(contract: "run_events", detail: "Historique tronqué. Reprise interrompue sans nouvel envoi.")
                }
                if profileLock?.state(key.bot, on: connection) == .unknown {
                    if replay[runKey]?.disconnectedAt == nil { replay[runKey]?.disconnectedAt = Date().timeIntervalSince1970 }
                    try await Task.sleep(for: approvalRetry)
                    continue
                }
                if let profileLock, let reason = profileLock.state(key.bot, on: connection).reason {
                    apply(.failed(key, reason), on: connection)
                    return
                }
                if case .pause = loopReports[runKey]?.verdict { return }
                if !turn.state.isTerminal {
                    closedWithoutProgress = replay[runKey]?.sequence == sequence ? closedWithoutProgress + 1 : 0
                    guard closedWithoutProgress < 3 else {
                        throw HermesError.decoding(contract: "run_events", detail: "Flux fermé trois fois sans progrès. Reprise interrompue sans nouvel envoi.")
                    }
                    throw HermesError.unreachable(url: client.baseURL.absoluteString, reason: "flux interrompu")
                }
                activeRuns[connection]?[stopTarget] = nil
                forget(runKey, run: run)
                if let events = loopEvents[runKey] {
                    let profile = ProfileKey(connection: connection, bot: key.bot)
                    let stats = LoopGuard.TurnStats(toolCalls: events.filter { $0.kind == .toolStarted }.count, tokens: events.compactMap(\.tokens).last)
                    loopHistory[profile] = Array((loopHistory[profile, default: []] + [stats]).suffix(LoopGuard.historyTurns))
                }
                apply(.ended(key, reply: turn.text, end: TurnEnd(turn.state), detail: turn.error), on: connection)
                return
            } catch {
                guard machines[connection]?.threads[key]?.run == run else { return }
                guard Self.isLinkFailure(error) else {
                    forget(runKey, run: run)
                    if connection == self.connection() { reportAPIError(error) }
                    apply(.failed(key, Self.message(error)), on: connection)
                    return
                }
                if replay[runKey]?.disconnectedAt == nil { replay[runKey]?.disconnectedAt = Date().timeIntervalSince1970 }
                if connection == self.connection() { reportAPIError(error) }
                do { try await Task.sleep(for: approvalRetry) } catch { return }
            }
        }
    }

    private func observeReplay(_ data: Data, key: RunKey, run: String) -> Bool {
        guard !isPaused(key, run: run) else { return false }
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }
        if event["event"] as? String == "replay.truncated" {
            replay[key]?.truncated = true
            return false
        }
        if key.connection == connection() { onAPIRecovered() }
        // Le lecteur reconstruit depuis le début ; les événements déjà vus ne changent ni la feuille ni le garde
        if let seq = event["seq"] as? Int {
            let fresh = seq > (replay[key]?.sequence ?? -1)
            replay[key]?.acceptsUpdates = fresh
            if !fresh { return true }
            replay[key]?.sequence = seq
        }
        if let disconnectedAt = replay[key]?.disconnectedAt {
            let downtime = Date().timeIntervalSince1970 - disconnectedAt
            loopEvents[key] = loopEvents[key]?.map { event in
                var event = event
                event.timestamp = event.timestamp.map { $0 + downtime }
                return event
            }
            replay[key]?.replayed = true
            replay[key]?.disconnectedAt = nil
        }
        return observeLoop(data, key: key, run: run)
    }

    private func updateReplay(_ turn: Turn, key: RunKey, run: String) {
        guard replay[key]?.acceptsUpdates == true, !isPaused(key, run: run) else { return }
        apply(.streamed(key.thread, turn.text), on: key.connection)
        apply(.observed(key.thread, tool: turn.tool, approval: turn.state == .waitingForApproval ? turn.approvals.last : nil), on: key.connection)
    }

    private func forget(_ key: RunKey, run: String) {
        guard let session = key.thread.session else { return }
        do { try resumeStore?.remove(.init(session: session, run: run), connection: key.connection, bot: key.thread.bot) }
        catch { if key.connection == connection() { onAPIError(error) } }
    }

    private func isPaused(_ key: RunKey, run: String) -> Bool {
        guard machines[key.connection]?.threads[key.thread]?.run == run else { return true }
        if let profileLock, profileLock.state(key.thread.bot, on: key.connection) != .free { return true }
        if case .pause = loopReports[key]?.verdict { return true }
        return false
    }

    private func observeLoop(_ data: Data, key: RunKey, run: String) -> Bool {
        guard machines[key.connection]?.threads[key.thread]?.run == run else { return false }
        if let profileLock, profileLock.state(key.thread.bot, on: key.connection) != .free { return false }
        if case .pause = loopReports[key]?.verdict { return false }
        guard var event = LoopGuard.Event.decode(data) else { return true }
        // Sans horodatage serveur, le silence part de la réception de l'événement
        if event.timestamp == nil || replay[key]?.replayed == true { event.timestamp = Date().timeIntervalSince1970 }
        loopEvents[key, default: []].append(event)
        return evaluateLoop(key)
    }

    private func evaluateLoop(_ key: RunKey) -> Bool {
        if case .pause = loopReports[key]?.verdict { return false }
        let report = LoopGuard.evaluate(events: loopEvents[key, default: []], history: loopHistory[ProfileKey(connection: key.connection, bot: key.thread.bot), default: []], now: Date().timeIntervalSince1970, canStopRun: false)
        loopReports[key] = report
        guard case .pause(let cause, _) = report.verdict else { return true }
        #if DEBUG
        pauseTimes[key] = Date().timeIntervalSince1970
        #endif
        notifications[key] = "Autorisation des notifications en attente."
        Task { notifications[key] = await notifyPause(cause) }
        return false
    }

    /// Un refus ne change pas le modèle montré ; la route a pu disparaître, la sonde le dit
    private func setModel(_ key: ConversationMachine.Key, model: String, on connection: String) async {
        guard await permits(key, on: connection) else { return }
        guard let session = key.session else { return }
        guard let client = client(connection) else { return apply(.modelFailed(key, Self.unreachable), on: connection) }
        do {
            let lock = try await client.setModel(profile: key.bot, session: session, model: model)
            apply(.modelSet(key, model: lock.model, read: startedReads()), on: connection)
        } catch {
            if connection == self.connection() { reportAPIError(error) }
            apply(.modelFailed(key, Self.message(error)), on: connection)
            await probeSupport(.setModel, bot: key.bot, on: connection, force: true)
        }
    }

    /// Envoie la décision ; une liaison coupée ne la perd pas : elle attend et repart tant que la demande l'attend
    /// Un refus de Hermes (HTTP 4xx) ne repart pas seul : l'utilisateur le lit et répond de nouveau. La route a pu disparaître : la sonde le dit
    private func approve(_ key: ConversationMachine.Key, run: String, request: ApprovalRequest, decision: ConversationMachine.Decision, on connection: String) async {
        let id = request.requestID
        while true {
            if await permits(key, on: connection, queueOnUnknown: true), let client = client(connection) {
                do {
                    _ = try await client.approve(profile: key.bot, run: run, request: request, choice: decision.choice)
                    return apply(.approved(key, requestID: id), on: connection)
                } catch {
                    if connection == self.connection() { reportAPIError(error) }
                    guard Self.isLinkFailure(error) else {
                        apply(.approvalFailed(key, requestID: id, Self.message(error)), on: connection)
                        return await probeSupport(.approve, bot: key.bot, on: connection, force: true)
                    }
                }
            }
            // la liaison est coupée, ou l'hôte a changé : la décision attend, puis repart
            apply(.approvalQueued(key, requestID: id), on: connection)
            try? await Task.sleep(for: approvalRetry)
            // le tour a fini, ou Hermes a clos la demande : plus rien à envoyer
            guard let approval = machines[connection]?.threads[key]?.approval, approval.request.requestID == id, approval.decision != nil, !approval.isSettled else { return }
        }
    }

    private func reportAPIError(_ error: Error) {
        if Self.isLinkFailure(error) { return onAPIError(error) }
        if case HermesError.http(_, let status, _) = error, status == 401 || status == 403 {
            onAPIError(error)
        }
    }

    /// Une panne de transport, ou un serveur qui n'a pas pu traiter la requête (502, 503, 504) : la décision n'a pas été prise
    private static func isLinkFailure(_ error: Error) -> Bool {
        switch error as? HermesError {
        case .unreachable: true
        case .http(_, let status, _): [502, 503, 504].contains(status)
        default: false
        }
    }

    func updateSupport(_ map: CapabilityMap, bot: String) {
        for entry in map.entries {
            let key = SupportKey(connection: connection(), bot: bot, contract: entry.contract)
            switch entry.state {
            case .available: support[key] = .available
            case .disabled(let message): support[key] = .disabled(message: message)
            }
        }
    }

    private func probeSupport(_ contract: Contract, bot: String, on connection: String, force: Bool) async {
        let key = SupportKey(connection: connection, bot: bot, contract: contract)
        guard force || support[key] == nil, let client = client(connection) else { return }
        guard let state = try? await client.capability(contract, profile: bot) else { return }
        // l'hôte a pu changer pendant la sonde : l'adresse de ce client peut déjà mener au nouvel hôte
        guard connection == self.connection() else { return }
        switch state {
        case .available: support[key] = .available
        case .disabled(let message): support[key] = .disabled(message: message)
        }
    }

    /// Après le tour, Hermes a numéroté les lignes : le transcript leur donne leur identifiant
    /// Une relecture qui échoue laisse l'écran tel qu'il est
    private func reread(_ key: ConversationMachine.Key, turn: Int, on connection: String) async {
        guard let session = key.session, let client = client(connection), let messages = try? await client.messages(profile: key.bot, session: session) else { return }
        apply(.reread(key, turn: turn, Self.lines(messages)), on: connection)
    }

    // MARK: Hermes vers l'écran

    private static let unreachable = String(localized: "Hermes n'est pas joignable.")

    private static func lines(_ messages: [Message]) -> [ConversationMachine.Line] {
        messages.map { ($0.id, $0.role == .user ? .user : .assistant, $0.text) }
    }

    private static func message(_ error: Error) -> String {
        if case HermesError.unreachable(let url, _) = error, url.isEmpty { return unreachable }
        return "\(error)"
    }
}

extension TurnEnd {
    /// nil pour un état qui n'est pas terminal : un flux qui s'arrête là n'est pas une fin de tour
    init?(_ state: TurnState) {
        switch state {
        case .completed: self = .completed
        case .failed: self = .failed
        case .cancelled: self = .cancelled
        case .interrupted: self = .interrupted
        case .running, .waitingForApproval: return nil
        }
    }
}
