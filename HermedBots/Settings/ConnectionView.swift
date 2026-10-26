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

/// L'alias du tunnel et les champs déduits de `ssh -G` ; aucun secret
struct ConnectionView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var apiProfile = "default"
    @State private var apiKey = ""
    @State private var apiStatus = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Alias SSH", text: $model.host).accessibilityID(.connectionHost)
                LabeledContent("Hôte") {
                    Text(verbatim: model.preview?.hostname ?? "—").accessibilityID(.connectionResolvedHost)
                }
                LabeledContent("Utilisateur") {
                    Text(verbatim: model.preview?.user ?? "—").accessibilityID(.connectionUser)
                }
                LabeledContent("Port") {
                    Text(verbatim: model.preview.map { String($0.port) } ?? "—").accessibilityID(.connectionPort)
                }
                LabeledContent("Identité") {
                    Text(verbatim: model.preview?.identity.label ?? "—").accessibilityID(.connectionIdentity)
                }
                LabeledContent(model.preview?.identityPresentTitle ?? String(localized: "Clé publique")) {
                    Text(verbatim: model.preview?.identityPresentLabel ?? "—").accessibilityID(.connectionIdentityPresent)
                }
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
            .onChange(of: model.host) {
                model.persistEndpoint()
                model.refreshPreview()
            }
            HStack {
                Button("Tester la connexion") { Task { await model.refreshVersion() } }
                    .accessibilityID(.connectionCheck)
                    .accessibilityRespondsToUserInteraction(true)
                Spacer(minLength: 0)
                Button("Fermer") { dismiss() }
                    .accessibilityID(.connectionClose)
                    .accessibilityRespondsToUserInteraction(true)
                Button("Connecter") { model.connect() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityID(.connectionConnect)
                    .accessibilityRespondsToUserInteraction(true)
            }
            .padding()
            .accessibilityElement(children: .contain)
        }
    }
}
