import SwiftUI

/// Pastille courte du verrou : même vue sur la carte et dans la barre latérale
struct BotLockPill: View {
    /// Marge droite depuis le surlignage de sélection de la barre latérale
    static let sidebarTrailing: CGFloat = 12
    /// Marge droite de la carte, égale à la marge gauche de l'avatar
    static let cardInset: CGFloat = 13
    /// Écart minimal entre le nom et la pastille
    static let nameSpacing: CGFloat = 8

    let label: String
    let help: String
    let accessibilityID: String

    var body: some View {
        Text(label)
            .font(.caption)
            .foregroundStyle(.orange)
            .lineLimit(1)
            .fixedSize()
            .layoutPriority(1)
            .help(help)
            .accessibilityIdentifier(accessibilityID)
    }
}
