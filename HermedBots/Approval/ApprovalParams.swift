import Foundation

/// Les paramètres d'une demande d'approbation, tels que la feuille les montre : jamais changés ni coupés sans que la feuille le dise
/// Les caractères de contrôle et de mise en forme (NUL, ESC, inversion du sens d'écriture, espace de largeur nulle) s'écrivent `\u{…}` : montrés tels quels, ils cacheraient une partie de la commande
/// Le texte montré est borné à `limit` caractères pour que la feuille reste fluide ; le reste est compté, pas jeté en silence
struct ApprovalParams: Equatable {
    static let limit = 50_000

    /// Le texte à afficher
    let shown: String
    /// Les caractères de la commande que la feuille ne montre pas
    let hidden: Int
    /// Les caractères écrits `\u{…}` dans le texte montré
    let escaped: Int
    /// Les caractères de la commande, en scalaires Unicode
    let total: Int

    /// La feuille doit dire ce qu'elle a changé ou caché
    var isChanged: Bool { hidden > 0 || escaped > 0 }

    init(_ command: String, limit: Int = Self.limit) {
        var shown = ""
        var length = 0
        var escaped = 0
        var consumed = 0
        for scalar in command.unicodeScalars {
            let isEscaped = Self.needsEscape(scalar)
            let piece = isEscaped ? "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}" : String(scalar)
            // la limite compte ce qui est montré : un NUL écrit en clair en prend cinq
            if length + piece.count > limit { break }
            shown += piece
            length += piece.count
            if isEscaped { escaped += 1 }
            consumed += 1
        }
        self.shown = shown
        self.escaped = escaped
        total = command.unicodeScalars.count
        hidden = total - consumed
    }

    /// Les caractères de contrôle, sauf le saut de ligne et la tabulation, et ceux de mise en forme
    private static func needsEscape(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\n" || scalar == "\t" { return false }
        switch scalar.properties.generalCategory {
        case .control, .format: return true
        default: return false
        }
    }
}
