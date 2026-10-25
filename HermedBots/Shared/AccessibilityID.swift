/// Chaque identifiant d'accessibilité `hd.*` de l'app, défini ici une seule fois et partagé avec la cible de tests UI
/// Convention : `hd.<écran>.<élément>[.<id-dynamique>]`, minuscules, kebab-case
/// L'id dynamique est un identifiant Hermes stable (profil, session, modèle), jamais un index d'affichage
enum AccessibilityID: String, CaseIterable {
    case stopAll = "hd.kill-switch.stop-all"
    case stopAllStatus = "hd.kill-switch.status"
    case approvalStopAll = "hd.approval.stop-all"
    case approvalStopStatus = "hd.approval.stop-status"
    case botsList = "hd.bots.list"
    case botsChange = "hd.bots.change"
    case botsChangeApply = "hd.bots.change.apply"
    case botsEmpty = "hd.bots.empty"
    case botsError = "hd.bots.error"
    case botsRetry = "hd.bots.retry"
    case resumeState = "hd.resume.state"
    case conversationView = "hd.conversation.view"
    case conversationState = "hd.conversation.state"
    case conversationEmpty = "hd.conversation.empty"
    case conversationBusy = "hd.conversation.busy"
    case conversationError = "hd.conversation.error"
    case profileLock = "hd.profile.lock"
    case composerInput = "hd.composer.input"
    case composerSend = "hd.composer.send"
    case sessionNew = "hd.session.new"
    case perfHang = "hd.perf.hang"
    /// Mode test seulement : les durées du clic sur l'option de modèle au modèle confirmé dans le sélecteur
    case perfLoopPause = "hd.perf.loop-pause"
    case perfModel = "hd.perf.model"
    case modelPicker = "hd.model.picker"
    /// Un choix attend la confirmation de Hermes
    case modelWaiting = "hd.model.waiting"
    case modelError = "hd.model.error"
    /// Le message de `set_model` désactivée : le sélecteur est grisé, le reste marche
    case modelDisabled = "hd.model.disabled"
    case approvalSheet = "hd.approval.sheet"
    case approvalTool = "hd.approval.tool"
    case approvalParams = "hd.approval.params"
    case approvalYes = "hd.approval.yes"
    case approvalNo = "hd.approval.no"
    /// Ce que la feuille dit de la réponse : le bot attend l'utilisateur, la réponse est partie, ou elle attend le retour de la liaison
    case approvalStatus = "hd.approval.status"
    /// Le marqueur des paramètres que la feuille ne montre pas en entier
    case approvalCut = "hd.approval.cut"
    /// Le message de `approve` désactivée : la demande reste affichée, la réponse est grisée
    case approvalDisabled = "hd.approval.disabled"
    /// Où trouver le moyen d'arrêter le bot quand on ne peut pas lui répondre
    case approvalKillSwitch = "hd.approval.kill-switch"
    case toolCurrent = "hd.tool.current"
    case bannerDegraded = "hd.banner.degraded"
    case bannerWaiting = "hd.banner.waiting"
    case bannerLoopPause = "hd.banner.loop-pause"
    case loopClose = "hd.loop.close"
    case loopTokens = "hd.loop.tokens"
    case loopNotification = "hd.loop.notification"
    case bannerError = "hd.banner.error"
    case bannerErrorRetry = "hd.banner.error.retry"
    case statusVersion = "hd.status.version"
    case connectionOpen = "hd.connection.open"
    case connectionHost = "hd.connection.host"
    case connectionUser = "hd.connection.user"
    case connectionResolvedHost = "hd.connection.resolved-host"
    case connectionPort = "hd.connection.port"
    case connectionJumps = "hd.connection.jumps"
    case connectionIdentity = "hd.connection.identity"
    case connectionIdentityPresent = "hd.connection.identity-present"
    case connectionTunnelState = "hd.connection.tunnel-state"
    case connectionVersion = "hd.connection.version"
    case connectionMessage = "hd.connection.message"
    case connectionConnect = "hd.connection.connect"
    case connectionCheck = "hd.connection.check"
    case connectionClose = "hd.connection.close"
    case connectionAPIProfile = "hd.connection.api-profile"
    case connectionAPIKey = "hd.connection.api-key"
    case connectionAPISave = "hd.connection.api-save"
    case connectionAPIStatus = "hd.connection.api-status"
    case updatesCheck = "hd.updates.check"
    case settingsConnection = "hd.settings.connection"
    case settingsUpdates = "hd.settings.updates"

    static func botRow(_ profileID: String) -> String { "hd.bots.row.\(profileID)" }
    static func botLock(_ profileID: String) -> String { "\(botRow(profileID)).lock" }
    static func botName(_ profileID: String) -> String { "\(botRow(profileID)).name" }
    static func botModel(_ profileID: String) -> String { "\(botRow(profileID)).model" }
    static func botThreads(_ profileID: String) -> String { "\(botRow(profileID)).threads" }
    static func threadRow(_ sessionID: String) -> String { "hd.threads.row.\(sessionID)" }
    /// Message des fils d'un bot : fonction `list_sessions` désactivée, aucun fil, ou lecture en échec
    static func threadsDisabled(_ profileID: String) -> String { "hd.threads.disabled.\(profileID)" }
    static func threadsEmpty(_ profileID: String) -> String { "hd.threads.empty.\(profileID)" }
    static func threadsError(_ profileID: String) -> String { "hd.threads.error.\(profileID)" }
    /// `index` est celui que Hermes fournit pour le message
    static func conversationMessage(_ index: Int) -> String { "hd.conversation.message.\(index)" }
    /// Un message que Hermes n'a pas encore numéroté porte la clé locale de la ligne, préfixée pour ne jamais passer pour un numéro
    static func conversationMessagePending(_ key: Int) -> String { "hd.conversation.message.pending-\(key)" }
    static func modelOption(_ modelID: String) -> String { "hd.model.option.\(modelID)" }
    /// `contract` est le nom logique du contrat désactivé, par exemple `set_model`
    static func degradedFeature(_ contract: String) -> String { "hd.banner.degraded.feature.\(contract)" }
}
