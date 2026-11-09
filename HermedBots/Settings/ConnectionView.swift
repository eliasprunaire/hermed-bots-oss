import AppSettings
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
}

/// L'alias du tunnel, les champs déduits de `ssh -G`, et la saisie de la clé API d'un profil
/// La clé saisie va au Trousseau ; aucun champ ne la montre
struct ConnectionView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var keyProfile = ""
    @State private var keyDraft = ""
    @State private var keyStatus: String?

    /// Les profils lus sur l'hôte ; vide tant que la liste n'est pas lue
    private var knownProfiles: [String] { (model.bots.list.shown ?? []).map(\.id) }

    private var chosenProfile: String {
        let typed = keyProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? (model.versionProfile ?? "") : typed
    }

    private func saveKey() {
        let profile = chosenProfile
        let draft = keyDraft
        // le champ est vidé avant tout : la valeur ne reste pas dans la vue, quel que soit le résultat
        keyDraft = ""
        Task {
            do {
                try await model.storeAPIKey(draft, profile: profile)
                keyStatus = String(localized: "Clé enregistrée dans le Trousseau pour le profil \(profile).")
            } catch is ManualAPIKeyError {
                keyStatus = String(localized: "La clé est vide ou sur plusieurs lignes. Colle la clé sur une seule ligne.")
            } catch is HermesProfileName {
                keyStatus = String(localized: "Le nom du profil n'est pas valide.")
            } catch {
                keyStatus = String(localized: "Le Trousseau a refusé la clé. Déverrouille-le, puis réessaie.")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Alias SSH", text: $model.host).accessibilityID(.connectionHost)
                Picker("Mode SSH", selection: Binding(
                    get: { model.authMode },
                    set: { mode in
                        model.authMode = mode
                        model.noteUserChoseAuthMode()
                    }
                )) {
                    ForEach(SSHAuthMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .accessibilityID(.connectionAuthMode)
                if model.authMode == .ephemeralAgent {
                    TextField("Commande de clé", text: $model.keyCommandPath)
                        .accessibilityID(.connectionKeyCommand)
                }
                if model.authMode == .wrapper {
                    TextField("Exécutable SSH", text: $model.wrapperPath)
                        .accessibilityID(.connectionWrapper)
                }
                LabeledContent("Hôte") {
                    Text(verbatim: model.preview?.hostname ?? "—").accessibilityID(.connectionResolvedHost)
                }
                LabeledContent("Utilisateur") {
                    Text(verbatim: model.preview?.user ?? "—").accessibilityID(.connectionUser)
                }
                LabeledContent(model.displayedPort?.settingsTitle ?? String(localized: "Port")) {
                    Text(verbatim: model.displayedPort?.settingsValue ?? "—").accessibilityID(.connectionPort)
                }
                LabeledContent("Identité") {
                    Text(verbatim: model.preview?.identity.label ?? "—").accessibilityID(.connectionIdentity)
                }
                // en mode Exécutable, l'app ne lit aucune clé : une ligne « présente / absente » serait fausse
                if model.preview?.identity != .executable {
                    LabeledContent(model.preview?.identityPresentTitle ?? String(localized: "Clé publique")) {
                        Text(verbatim: model.preview?.identityPresentLabel ?? "—").accessibilityID(.connectionIdentityPresent)
                    }
                }
                LabeledContent("Tunnel") { Text(model.tunnel.state.label).accessibilityID(.connectionTunnelState) }
                LabeledContent("Version de Hermes") { model.version.text.accessibilityID(.connectionVersion) }
                if let message = model.tunnel.state.failureMessage {
                    Text(message).foregroundStyle(.red).accessibilityID(.connectionMessage)
                }
                Section("Clé API d'un profil") {
                    if knownProfiles.isEmpty {
                        TextField("Profil", text: $keyProfile, prompt: Text(verbatim: model.versionProfile ?? ""))
                            .accessibilityID(.connectionApiKeyProfile)
                    } else {
                        Picker("Profil", selection: Binding(get: { chosenProfile }, set: { keyProfile = $0 })) {
                            ForEach(knownProfiles, id: \.self) { Text(verbatim: $0).tag($0) }
                        }
                        .accessibilityID(.connectionApiKeyProfile)
                    }
                    SecureField("Clé API", text: $keyDraft)
                        .accessibilityID(.connectionApiKey)
                    Button("Enregistrer la clé") { saveKey() }
                        .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chosenProfile.isEmpty)
                        .accessibilityID(.connectionApiKeySave)
                        .accessibilityRespondsToUserInteraction(true)
                    if let keyStatus {
                        Text(keyStatus).accessibilityID(.connectionApiKeyStatus)
                    }
                }
            }
            .formStyle(.grouped)
            .onChange(of: model.host) {
                model.persistEndpoint()
                model.refreshPreview()
            }
            .onChange(of: model.wrapperPath) { model.persistEndpoint() }
            .onChange(of: model.keyCommandPath) {
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
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityID(.connectionConnect)
                    .accessibilityRespondsToUserInteraction(true)
            }
            .padding()
            .accessibilityElement(children: .contain)
        }
    }
}
