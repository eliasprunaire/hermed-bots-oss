import SwiftUI

extension SSHTunnel.State {
    var label: String {
        switch self {
        case .idle: String(localized: "fermé")
        case .opening: String(localized: "ouverture")
        case .open: String(localized: "ouvert")
        case .reopening(let attempt): String(localized: "réouverture, essai \(attempt)")
        case .failed: String(localized: "en échec")
        }
    }

    /// Le texte du bandeau de la fenêtre principale ; nil quand le tunnel va bien ou n'est pas demandé
    var bannerMessage: String? {
        switch self {
        case .failed(let failure): failure.message
        case .reopening: String(localized: "Le tunnel est tombé. Réouverture en cours.")
        case .idle, .opening, .open: nil
        }
    }

    var failureMessage: String? {
        if case .failed(let failure) = self { failure.message } else { nil }
    }
}

extension AppModel.KeyState {
    var label: String {
        switch self {
        case .unread: String(localized: "pas encore lue")
        case .present: String(localized: "présente dans le Trousseau")
        case .absent: String(localized: "absente du Trousseau")
        case .unreadable: String(localized: "illisible")
        }
    }
}

/// L'hôte du tunnel et l'état de la clé ; la valeur de la clé ne s'affiche jamais
struct ConnectionView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var apiProfile = "default"
    @State private var apiKey = ""
    @State private var apiStatus = ""

    var body: some View {
        Form {
            TextField("Hôte", text: $model.host).accessibilityID(.connectionHost)
            TextField("Utilisateur", text: $model.user).accessibilityID(.connectionUser)
            LabeledContent("Clé SSH") { Text(model.keyState.label).accessibilityID(.connectionKeyState) }
            LabeledContent("Tunnel") { Text(model.tunnel.state.label).accessibilityID(.connectionTunnelState) }
            LabeledContent("Version de Hermes") { model.version.text.accessibilityID(.connectionVersion) }
            Section("Clé API par profil") {
                Picker("Profil", selection: $apiProfile) {
                    ForEach(Array(Set(["default"] + (model.bots.list.shown ?? []).map(\.id))).sorted(), id: \.self) { profile in
                        Text(verbatim: profile).tag(profile)
                    }
                }
                .accessibilityID(.connectionAPIProfile)
                .onChange(of: apiProfile) { apiKey = ""; apiStatus = "" }
                SecureField("Nouvelle clé API", text: $apiKey).accessibilityID(.connectionAPIKey)
                Button("Enregistrer la clé") {
                    do {
                        try model.saveAPIKey(apiKey, profile: apiProfile)
                        apiKey = ""
                        apiStatus = String(localized: "Clé enregistrée.")
                        Task { await model.retryAPI() }
                    } catch {
                        apiKey = ""
                        apiStatus = String(localized: "La clé n’a pas pu être enregistrée.")
                    }
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityID(.connectionAPISave)
                Text(verbatim: apiStatus).accessibilityID(.connectionAPIStatus)
            }
            if let message = model.tunnel.state.failureMessage {
                Text(message).foregroundStyle(.red).accessibilityID(.connectionMessage)
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.host) { model.persistEndpoint() }
        .onChange(of: model.user) { model.persistEndpoint() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button("Tester la connexion") { Task { await model.refreshVersion() } }.accessibilityID(.connectionCheck)
                Spacer()
                Button("Fermer") { dismiss() }.accessibilityID(.connectionClose)
                Button("Connecter") { model.connect() }.keyboardShortcut(.defaultAction).accessibilityID(.connectionConnect)
            }
            .padding()
        }
    }
}
