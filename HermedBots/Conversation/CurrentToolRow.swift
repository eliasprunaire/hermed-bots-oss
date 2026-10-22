import SwiftUI

/// La ligne « outil en cours » : le nom de l'outil que Hermes dit en cours, tant qu'il tourne
/// Le libellé d'accessibilité est le texte entier (« Outil en cours : shell.exec »), que VoiceOver lit tel quel
struct CurrentToolRow: View {
    let tool: String

    var body: some View {
        Label {
            Text("Outil en cours : \(tool)")
        } icon: {
            Image(systemName: "wrench.and.screwdriver")
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityID(.toolCurrent)
    }
}
