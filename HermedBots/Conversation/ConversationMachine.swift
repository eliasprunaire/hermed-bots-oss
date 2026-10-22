import Foundation
import HermesAdapter

/// La machine d'états de la conversation : ce que l'écran montre, l'état de chaque fil, et une transition par événement
/// Logique pure : `ConversationModel` exécute les effets (réseau) et rend chaque résultat sous la forme d'un événement qui porte le fil qui l'a lancé
///
/// Chaque fil a son état (`ThreadState`) : son étape, ses lignes et la fin de son dernier tour. L'écran montre un seul fil (`screen`)
/// Un résultat s'applique au fil qui a lancé l'opération, que ce fil soit à l'écran ou non : il n'est jamais perdu ni montré dans un autre fil
///
///     ready ──── open ──────▶ loading ─── loaded, failed ───▶ ready
///     ready ──── send ──────▶ sending ─── ended, failed ────▶ ready
///                               └── fil pas encore créé : created lui donne son identifiant, puis run
///     nouveau fil ─ newSession ─▶ creating ── created, failed ──▶ ready
///
/// | Événement            | État du fil concerné          | État après                                      | Effets                          |
/// |----------------------|-------------------------------|-------------------------------------------------|---------------------------------|
/// | select(bot)          | écran sur un autre bot        | écran : le fil pas encore créé du bot, ready    | aucun                           |
/// | open(fil)            | inconnu ou ready              | loading, l'écran passe dessus                   | load                            |
/// | open(fil)            | loading, creating ou sending  | inchangé, l'écran passe dessus                  | aucun                           |
/// | open(fil, modèle, lecture) | lecture partie après la confirmation du dernier choix de ce fil, aucun choix en vol | le fil prend le modèle de la liste, s'il y en a un | comme open(fil) |
/// | send(brouillon)      | à l'écran, ready              | sending, message ajouté                         | create(message) ou run          |
/// | newSession           | à l'écran, pas creating       | nouveau fil pas encore créé, creating, à l'écran | create                         |
/// | loaded(lignes)       | loading                       | ready, transcript, fin du dernier tour gardée   | aucun                           |
/// | created(session)     | creating                      | ready, le fil prend son identifiant Hermes      | threadsChanged                  |
/// | created(session)     | sending                       | sending, le fil prend son identifiant Hermes    | run, threadsChanged             |
/// | streamed(texte)      | sending                       | sending, la réponse grandit                     | aucun                           |
/// | ended(fin)           | sending                       | ready, fin annoncée par Hermes                  | reread si à l'écran, threadsChanged |
/// | reread(tour, lignes) | ready, même tour              | ready, lignes numérotées par Hermes             | aucun                           |
/// | failed(erreur)       | loading, creating ou sending  | ready, erreur sur ce fil (Hermes injoignable compris) | aucun                     |
/// | pickModel(modèle)    | fil créé, aucun choix en vol  | choix en vol (`pendingModel`), modèle affiché inchangé | setModel                 |
/// | pickModel(modèle)    | fil pas encore créé           | `chosenModel` : affiché tout de suite, pas confirmé | aucun                       |
/// | pickModel(modèle)    | choix en vol, ou même modèle  | inchangé                                        | aucun                           |
/// | modelSet(modèle, lecture) | choix en vol             | le fil prend le modèle que Hermes annonce et retient la lecture | run si un premier tour attendait |
/// | modelFailed(erreur)  | choix en vol                  | choix libéré, modèle inchangé, erreur sur le fil | aucun                          |
/// | modelFailed(erreur)  | choix en vol, premier tour en attente | idem, et le tour échoue sans être parti | aucun                           |
/// | created(session)     | fil avec `chosenModel`        | le choix devient `pendingModel` ; un premier tour attend sa confirmation | setModel, threadsChanged |
/// | runStarted(run)      | sending                       | le fil garde le run du tour                     | aucun                           |
/// | observed(outil, demande) | sending                   | l'outil en cours ; une demande neuve attend l'utilisateur, une demande absente ferme la feuille | probeApprove si la demande est neuve |
/// | answer(décision)     | à l'écran, sending, demande qui attend | la décision est prise, une seule fois (un double clic ne la change pas) | approve |
/// | approved(demande)    | décision prise                | la feuille se ferme ; la demande reste connue tant que le flux la montre | aucun        |
/// | approvalQueued(demande) | décision prise             | la décision attend la liaison, la feuille reste | aucun (le modèle réessaie)      |
/// | approvalFailed(demande, erreur) | décision prise     | la décision est libre, l'erreur est montrée     | aucun                           |
/// | ended, failed        | sending                       | plus de run, d'outil ni de demande              | voir ci-dessus                  |
/// | tout résultat        | autre état                    | inchangé : le résultat est dépassé              | aucun                           |
///
/// Le modèle d'un fil est celui que `set_model` a verrouillé sur sa session (S4) ; nil : le fil suit le modèle du profil
/// `POST /v1/runs` ignore le verrou : chaque `run` porte le modèle du fil, et le choix d'un fil ne touche jamais un autre fil
/// Un choix pendant un tour ne touche pas au tour : `set_model` ne regarde pas le run en cours, le choix vaut pour le tour suivant
/// Un choix fait avant que le fil existe (`chosenModel`) n'est pas un modèle confirmé : `created` le verrouille, le premier tour attend la confirmation, et un refus abandonne le choix
struct ConversationMachine: Equatable {
    /// Un fil chez Hermes, ou un fil pas encore créé d'un bot (numéro local) : le premier envoi ou « Nouvelle session » le crée
    enum Thread: Hashable, Sendable {
        case session(String)
        case unsaved(Int)
    }

    struct Key: Hashable, Sendable {
        let bot: String
        let thread: Thread

        /// Le fil chez Hermes ; nil tant qu'il n'est pas créé
        var session: String? {
            if case .session(let id) = thread { id } else { nil }
        }
    }

    /// L'état d'un fil
    enum Step: Equatable, Sendable {
        /// Rien en vol : Envoyer est permis
        case ready
        /// Réouverture : Hermes lit le transcript
        case loading
        /// « Nouvelle session » : Hermes crée le fil
        case creating
        /// Un tour, de l'envoi à l'état final : création du fil s'il n'existe pas, `start_run`, `run_events`
        case sending
    }

    struct ThreadState: Equatable {
        var step = Step.ready
        var conversation = Conversation()
        /// Nombre de tours envoyés dans ce fil : une relecture porte le sien et ne s'applique qu'à ce tour
        var turns = 0
        /// Le modèle de ce fil, tel que Hermes l'a annoncé (verrou `set_model`, ou entrée de `list_sessions`) ; nil : le fil suit le modèle du profil
        var model: String?
        /// Le numéro de la dernière lecture de la liste des fils partie quand Hermes a confirmé le dernier choix fait ici
        /// Une lecture de numéro inférieur ou égal est partie avant cette confirmation, en cache ou en vol : elle ne voit pas le choix et ne le défait pas
        /// Une lecture partie après fait foi, même quand elle redonne la valeur d'avant le choix : un autre client a remis cette valeur
        var confirmedRead = 0
        /// Le choix de l'utilisateur dans un fil pas encore créé : Hermes ne l'a pas vu, `created` le verrouille
        var chosenModel: String?
        /// Le modèle demandé à `set_model` et pas encore confirmé : le sélecteur attend, le modèle affiché ne change pas
        var pendingModel: String?
        /// Le premier message d'un fil neuf, qui attend la confirmation du verrou pour partir sur le modèle choisi
        var waitingMessage: String?
        /// Le refus de la dernière demande de modèle : ce n'est pas un échec du tour
        var modelError: String?
        /// Le run du tour en vol (`start_run`) : `approve` en a besoin ; nil hors tour
        var run: String?
        /// L'outil que Hermes dit en cours (`tool.started` sans `tool.completed`)
        var tool: String?
        /// La demande d'approbation que le flux a montrée et que Hermes attend
        var approval: Approval?

        /// La demande que la feuille montre : elle attend l'utilisateur ou sa décision
        var pendingApproval: Approval? { approval.flatMap { $0.isSettled ? nil : $0 } }

        /// Ce que le sélecteur montre : le choix pas encore envoyé à Hermes, sinon le modèle confirmé
        var shownModel: String? { chosenModel ?? model }
    }

    /// La réponse de l'utilisateur à une demande d'approbation ; `choice` est le mot que `approve` envoie
    /// Oui vaut `once`, cette demande seulement : `session` et `always` élargiraient l'accord au-delà de ce que la feuille montre
    enum Decision: Equatable, Sendable {
        case yes
        case no

        var choice: String { self == .yes ? "once" : "deny" }
    }

    /// Une demande d'approbation du bot, de son arrivée à la décision que Hermes a prise
    struct Approval: Equatable, Sendable {
        let request: ApprovalRequest
        /// La réponse de l'utilisateur ; nil : le bot attend
        var decision: Decision?
        /// La décision n'a pas pu partir : Hermes est injoignable, elle repart au retour de la liaison
        var isQueued = false
        /// Hermes a pris la décision : la feuille se ferme, mais la demande reste connue tant que le flux la montre
        var isSettled = false
        /// Le refus de la dernière décision par Hermes : l'utilisateur peut répondre de nouveau
        var error: String?
    }

    typealias Line = (serverIndex: Int, role: ConversationEntry.Role, text: String)

    enum Event: Sendable {
        // l'utilisateur
        case select(bot: String)
        /// `model` est celui de l'entrée de `list_sessions`, `read` le numéro pris au départ par la lecture de la liste qui le donne (0 : liste pas lue)
        /// Un fil prend le `model` d'une lecture partie après la confirmation de son dernier choix, jamais celui d'une lecture partie avant
        case open(session: String, bot: String, model: String? = nil, read: Int = 0)
        case send(String)
        case newSession
        case pickModel(String)
        // Hermes : chaque résultat porte le fil qui a lancé l'opération
        case loaded(Key, [Line])
        case created(Key, session: String, message: String?)
        case stopped(Key, run: String, end: TurnEnd)
        case streamed(Key, String)
        /// `end` vaut nil pour un flux qui s'arrête sans état terminal
        case ended(Key, reply: String, end: TurnEnd?, detail: String?)
        case reread(Key, turn: Int, [Line])
        /// Une lecture, une création ou un tour qui échoue, Hermes injoignable compris
        case failed(Key, String)
        /// `model` est celui que Hermes annonce, qui peut différer de celui demandé
        /// `read` est le numéro de la dernière lecture de la liste des fils partie au moment de la confirmation
        case modelSet(Key, model: String, read: Int = 0)
        case modelFailed(Key, String)
        /// `start_run` a rendu le run du tour
        case runStarted(Key, run: String)
        case restored(Key, run: String, lines: [Line])
        /// Le tour tel que le flux le montre : l'outil en cours, et la demande que Hermes attend (nil : aucune)
        case observed(Key, tool: String?, approval: ApprovalRequest?)
        /// L'utilisateur répond à la demande du fil à l'écran
        case answer(Decision)
        /// Hermes a pris la décision
        case approved(Key, requestID: String)
        /// La décision n'a pas pu partir (liaison coupée) : elle reste, le modèle réessaie
        case approvalQueued(Key, requestID: String)
        /// Hermes a refusé la décision
        case approvalFailed(Key, requestID: String, String)
    }

    enum Effect: Equatable, Sendable {
        /// `session_messages`, puis `loaded` ou `failed`
        case load(Key)
        /// `new_session`, puis `created` ou `failed` ; `message` est le premier envoi qui attend ce fil
        case create(Key, message: String?)
        /// `start_run` puis `run_events` : `streamed` à chaque texte, puis `ended` ou `failed`
        /// `model` part dans le corps du run : `POST /v1/runs` ignore le verrou de la session
        case run(Key, message: String, model: String? = nil)
        /// `set_model`, puis `modelSet` ou `modelFailed`
        case setModel(Key, model: String)
        /// `session_messages` après un tour, puis `reread` ; un échec ne change rien
        case reread(Key, turn: Int)
        case threadsChanged(bot: String)
        /// `approve` avec la décision, puis `approved`, `approvalQueued` (liaison coupée : le modèle repart) ou `approvalFailed`
        case approve(Key, run: String, request: ApprovalRequest, decision: Decision)
        /// La sonde de la route `approve`, une fois par bot et par hôte : une route retirée grise la réponse, la demande reste affichée
        case probeApprove(Key)
    }

    /// Le fil à l'écran ; nil tant qu'aucun bot n'est choisi
    private(set) var screen: Key?
    private(set) var threads: [Key: ThreadState] = [:]
    private var nextUnsaved = 0

    /// L'état du fil à l'écran
    var shown: ThreadState { screen.flatMap { threads[$0] } ?? ThreadState() }

    /// Envoyer exige un fil à l'écran, rien en vol dans ce fil et un brouillon non vide
    func canSend(_ draft: String) -> Bool {
        screen != nil && shown.step == .ready && shown.conversation.canSend(draft)
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .select(let bot):
            guard screen?.bot != bot else { return [] }
            // un fil pas encore créé de ce bot, laissé avec un message ou une erreur, reste le sien : on y revient
            let kept = threads.keys.compactMap { key -> (Int, Key)? in
                guard key.bot == bot, case .unsaved(let number) = key.thread else { return nil }
                return (number, key)
            }.max { $0.0 < $1.0 }?.1
            show(kept ?? unsaved(bot))
            return []

        case .open(let session, let bot, let model, let read):
            let key = Key(bot: bot, thread: .session(session))
            show(key)
            // une lecture partie avant la confirmation du dernier choix ne le voit pas : seule une lecture partie après fait foi, jamais sur un choix en vol
            // un modèle nil ne défait rien : la liste ne dit pas « aucun verrou » autrement que par un fil absent ou une lecture partie avant le verrou
            if let model, let thread = threads[key], read > thread.confirmedRead, thread.pendingModel == nil { threads[key]?.model = model }
            // une opération en vol dans ce fil le tient à jour : rien à relire
            guard threads[key]?.step == .ready else { return [] }
            threads[key]?.step = .loading
            return [.load(key)]

        case .send(let draft):
            guard let key = screen, canSend(draft), var thread = threads[key], let text = thread.conversation.begin(draft) else { return [] }
            thread.step = .sending
            thread.turns += 1
            threads[key] = thread
            return key.session == nil ? [.create(key, message: text)] : [.run(key, message: text, model: thread.model)]

        case .newSession:
            // le second clic d'un double clic trouve la création en cours
            guard let bot = screen?.bot, shown.step != .creating else { return [] }
            let key = unsaved(bot)
            show(key)
            threads[key]?.step = .creating
            return [.create(key, message: nil)]

        case .loaded(let key, let lines):
            guard threads[key]?.step == .loading else { return [] }
            threads[key]?.conversation.open(lines)
            threads[key]?.step = .ready
            return []

        case .created(let key, let session, let message):
            guard var thread = threads[key], key.session == nil, thread.step == .creating || thread.step == .sending else { return [] }
            let saved = Key(bot: key.bot, thread: .session(session))
            threads[key] = nil
            if screen == key { screen = saved }
            var effects: [Effect] = [.threadsChanged(bot: key.bot)]
            // un modèle choisi avant la création se verrouille sur le fil créé : le premier tour attend la confirmation, pour partir sur le modèle choisi
            if let model = thread.chosenModel {
                thread.chosenModel = nil
                thread.pendingModel = model
                effects.append(.setModel(saved, model: model))
                if thread.step == .sending, let message { thread.waitingMessage = message } else { thread.step = .ready }
                threads[saved] = thread
                return effects
            }
            guard thread.step == .sending, let message else {
                thread.step = .ready
                threads[saved] = thread
                return effects
            }
            threads[saved] = thread
            return effects + [.run(saved, message: message, model: thread.model)]

        case .streamed(let key, let reply):
            guard threads[key]?.step == .sending else { return [] }
            threads[key]?.conversation.receive(reply: reply)
            return []

        case .stopped(let key, let run, let end):
            guard var thread = threads[key], thread.run == run || thread.run == nil && thread.step == .ready else { return [] }
            thread.run = nil
            thread.tool = nil
            thread.approval = nil
            thread.conversation.finish(end)
            thread.step = .ready
            threads[key] = thread
            return [.threadsChanged(bot: key.bot)]

        case .ended(let key, let reply, let end, let detail):
            guard var thread = threads[key], thread.step == .sending else { return [] }
            thread.run = nil
            thread.tool = nil
            thread.approval = nil
            thread.conversation.receive(reply: reply)
            if let end {
                thread.conversation.finish(end, detail: detail)
            } else {
                thread.conversation.fail(String(localized: "Le flux s'est arrêté avant la fin du tour."))
            }
            thread.step = .ready
            threads[key] = thread
            // un fil qui n'est pas à l'écran se relira à sa réouverture
            return (screen == key ? [.reread(key, turn: thread.turns)] : []) + [.threadsChanged(bot: key.bot)]

        case .reread(let key, let turn, let lines):
            guard let thread = threads[key], thread.step == .ready, thread.turns == turn else { return [] }
            threads[key]?.conversation.sync(lines)
            return []

        case .failed(let key, let message):
            guard let step = threads[key]?.step, step != .ready else { return [] }
            threads[key]?.conversation.fail(message)
            threads[key]?.step = .ready
            threads[key]?.run = nil
            threads[key]?.tool = nil
            threads[key]?.approval = nil
            return []

        case .pickModel(let model):
            guard let key = screen, var thread = threads[key], thread.pendingModel == nil, thread.shownModel != model else { return [] }
            thread.modelError = nil
            // pas de session où verrouiller : le choix est retenu, `created` le verrouille
            guard key.session != nil else {
                thread.chosenModel = model
                threads[key] = thread
                return []
            }
            thread.pendingModel = model
            threads[key] = thread
            return [.setModel(key, model: model)]

        case .modelSet(let key, let model, let read):
            guard var thread = threads[key], thread.pendingModel != nil else { return [] }
            thread.model = model
            thread.confirmedRead = read
            thread.pendingModel = nil
            thread.modelError = nil
            let message = thread.waitingMessage
            thread.waitingMessage = nil
            threads[key] = thread
            return message.map { [.run(key, message: $0, model: model)] } ?? []

        case .modelFailed(let key, let error):
            guard var thread = threads[key], thread.pendingModel != nil else { return [] }
            thread.pendingModel = nil
            thread.modelError = error
            // le premier tour n'est pas parti : il ne part pas sur un autre modèle que celui qui a été choisi
            if thread.waitingMessage != nil {
                thread.waitingMessage = nil
                thread.conversation.fail(error)
                thread.step = .ready
            }
            threads[key] = thread
            return []

        case .restored(let key, let run, let lines):
            guard threads[key] == nil else { return [] }
            threads[key] = ThreadState()
            if screen == nil || screen?.bot == key.bot && screen?.session == nil { screen = key }
            threads[key]?.conversation.open(lines)
            threads[key]?.conversation.resume()
            threads[key]?.step = .sending
            threads[key]?.run = run
            return []

        case .runStarted(let key, let run):
            guard threads[key]?.step == .sending else { return [] }
            threads[key]?.run = run
            return []

        case .observed(let key, let tool, let request):
            guard var thread = threads[key], thread.step == .sending else { return [] }
            // la même demande, vue dans un autre événement du flux, garde son état : une demande close ne rouvre pas la feuille
            let isNewRequest = request != nil && thread.approval?.request.requestID != request?.requestID
            // Hermes n'attend plus de réponse : délai, ou une réponse d'un autre client
            let isClosed = request == nil && thread.approval != nil
            // la plupart des événements du flux (un mot de la réponse) ne changent ni l'outil ni la demande : rien à écrire
            guard thread.tool != tool || isNewRequest || isClosed else { return [] }
            thread.tool = tool
            if isClosed { thread.approval = nil }
            if let request, isNewRequest { thread.approval = Approval(request: request) }
            threads[key] = thread
            return isNewRequest ? [.probeApprove(key)] : []

        case .answer(let decision):
            guard let key = screen, var thread = threads[key], thread.step == .sending, var approval = thread.pendingApproval, approval.decision == nil, let run = thread.run else { return [] }
            approval.decision = decision
            approval.error = nil
            thread.approval = approval
            threads[key] = thread
            return [.approve(key, run: run, request: approval.request, decision: decision)]

        case .approved(let key, let requestID):
            guard threads[key]?.approval?.request.requestID == requestID else { return [] }
            threads[key]?.approval?.isQueued = false
            threads[key]?.approval?.isSettled = true
            return []

        case .approvalQueued(let key, let requestID):
            guard let approval = threads[key]?.approval, approval.request.requestID == requestID, approval.decision != nil, !approval.isSettled else { return [] }
            threads[key]?.approval?.isQueued = true
            return []

        case .approvalFailed(let key, let requestID, let error):
            guard let approval = threads[key]?.approval, approval.request.requestID == requestID, approval.decision != nil, !approval.isSettled else { return [] }
            threads[key]?.approval?.decision = nil
            threads[key]?.approval?.isQueued = false
            threads[key]?.approval?.error = error
            return []
        }
    }

    /// L'écran passe sur `key` ; un fil pas encore créé qu'on quitte sans rien y avoir fait disparaît
    private mutating func show(_ key: Key) {
        if let old = screen, old != key, old.session == nil, threads[old] == ThreadState() { threads[old] = nil }
        if threads[key] == nil { threads[key] = ThreadState() }
        screen = key
    }

    private mutating func unsaved(_ bot: String) -> Key {
        defer { nextUnsaved += 1 }
        return Key(bot: bot, thread: .unsaved(nextUnsaved))
    }
}
