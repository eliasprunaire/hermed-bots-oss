/// Un bot de la barre latérale : un profil Hermes actif
struct Bot: Equatable, Identifiable, Sendable {
    let id: String
    /// Le nom affiché : l'id du profil tant que Hermes ne donne aucun nom
    let name: String
    let model: String?

    static let paletteCount = 12

    /// Le dégradé du bot, tiré de son identifiant de profil : le même d'un lancement à l'autre, même si Hermes renomme le bot
    /// FNV-1a et non `Hasher`, dont la graine change à chaque lancement
    var palette: Int {
        let hash = id.utf8.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
        return Int(hash % UInt64(Self.paletteCount))
    }

    /// Les initiales du premier et du dernier mot du nom, « ? » quand le nom n'a ni lettre ni chiffre
    var monogram: String {
        let words = name.split { !$0.isLetter && !$0.isNumber }
        guard let first = words.first?.first else { return "?" }
        let last = words.count > 1 ? words.last?.first.map(String.init) ?? "" : ""
        return (String(first) + last).uppercased()
    }
}

/// La liste affichée et, à part, le changement que l'utilisateur n'a pas encore validé
/// Le premier relevé s'affiche tout de suite, il n'y a rien à comparer ; ensuite une liste d'identifiants différente attend `validate()`
struct BotList: Equatable {
    struct Change: Equatable {
        let added: [String]
        let removed: [String]
    }

    /// nil tant qu'aucun relevé n'est arrivé ; vide quand Hermes n'a aucun profil actif
    private(set) var shown: [Bot]?
    private var pending: [Bot]?

    var change: Change? {
        guard let shown, let pending else { return nil }
        let before = Set(shown.map(\.id)), after = Set(pending.map(\.id))
        return Change(added: pending.map(\.id).filter { !before.contains($0) }, removed: shown.map(\.id).filter { !after.contains($0) })
    }

    mutating func receive(_ fresh: [Bot]) {
        guard let current = shown else {
            shown = fresh
            return
        }
        // les mêmes profils : seuls les modèles ont pu bouger, rien à valider
        if Set(current.map(\.id)) == Set(fresh.map(\.id)) {
            shown = fresh
            pending = nil
        } else {
            pending = fresh
        }
    }

    mutating func validate() {
        guard let pending else { return }
        shown = pending
        self.pending = nil
    }
}
