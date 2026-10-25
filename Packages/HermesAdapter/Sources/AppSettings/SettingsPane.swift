import UpdateCheck

public enum SettingsPane: String, CaseIterable, Sendable {
    case connection
    case updates

    public var title: String {
        switch self {
        case .connection: "Connexion"
        case .updates: "Mises à jour"
        }
    }

    public var systemImage: String {
        switch self {
        case .connection: "network"
        case .updates: "arrow.down.app"
        }
    }

    public var accessibilityID: String {
        switch self {
        case .connection: "hd.settings.connection"
        case .updates: "hd.settings.updates"
        }
    }
}

public enum SettingsCopy {
    public static let checkForUpdates = "Rechercher les mises à jour…"
}

public enum UpdatesSettingsAction {
    public static func perform(_ updates: UpdateCheck) {
        updates.checkForUpdates()
    }
}
