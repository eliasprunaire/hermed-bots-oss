import SwiftUI

/// La ligne « outil en cours » : le nom de l'outil que Hermes dit en cours, tant qu'il tourne, dans une pastille dont l'engrenage tourne
/// Le libellé d'accessibilité est le texte entier (« Outil en cours : shell.exec »), que VoiceOver lit tel quel
struct CurrentToolRow: View {
    let tool: String
    @Environment(\.motion) private var motion

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "gearshape.2.fill")
                .symbolEffect(.rotate, isActive: motion)
                .accessibilityHidden(true)
            Text("Outil en cours : \(tool)")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityID(.toolCurrent)
    }
}
