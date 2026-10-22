import SwiftUI

struct ErrorBanner: View {
    let model: AppModel

    var body: some View {
        if let message = model.tunnel.state.bannerMessage ?? model.apiError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).accessibilityID(.bannerError)
                Spacer()
                Button("Réessayer") {
                    if case .failed = model.tunnel.state { model.connect() }
                    else { Task { await model.retryAPI() } }
                }
                .disabled(model.isCheckingAPI)
                .accessibilityID(.bannerErrorRetry)
            }
            .padding(10)
            .background(.bar)
        } else if model.isCheckingAPI {
            HStack {
                ProgressView().controlSize(.small)
                Text("Connexion à Hermes…").accessibilityID(.bannerWaiting)
                Spacer()
            }
            .padding(10)
        }
    }
}
