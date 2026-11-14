import SwiftUI

/// Le bandeau d'erreur de la liaison : il reste tant que le tunnel ou l'API sont en échec, avec Réessayer
/// Il flotte comme `ConnectingPill` : hauteur de pile nulle, l'accueil 401/down n'est pas poussé hors du pied
struct ErrorBanner: View {
    let model: AppModel

    var body: some View {
        banner
            .frame(maxWidth: .infinity, alignment: .top)
            .frame(height: 0, alignment: .top)
    }

    @ViewBuilder private var banner: some View {
        if let message = model.tunnel.state.bannerMessage ?? model.apiError {
            NoticeCard(tint: .orange, symbol: "exclamationmark.triangle.fill") {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(message).accessibilityID(.bannerError)
                    Spacer(minLength: 0)
                    Button("Réessayer") {
                        if case .failed = model.tunnel.state { model.connect() }
                        else { Task { await model.retryAPI() } }
                    }
                    .buttonStyle(.glass)
                    .disabled(model.isCheckingAPI)
                    .accessibilityID(.bannerErrorRetry)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// La lecture de la version en cours : une pastille qui flotte en haut de la fenêtre, sans pousser le contenu
struct ConnectingPill: View {
    let model: AppModel

    var body: some View {
        if (model.isCheckingAPI || model.conversation.isOpening), model.tunnel.state.bannerMessage == nil, model.apiError == nil, model.conversation.openError == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Connexion à Hermes…").accessibilityID(.bannerWaiting)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
            .padding(.top, 10)
            .transition(.opacity)
        }
    }
}
