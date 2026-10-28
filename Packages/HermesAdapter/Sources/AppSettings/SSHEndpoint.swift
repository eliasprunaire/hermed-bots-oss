import Foundation

/// Comment l'app obtient l'identité SSH : agent de session, agent temporaire, ou exécutable
public enum SSHAuthMode: String, Sendable, Equatable, CaseIterable {
    case sessionAgent
    case ephemeralAgent
    case wrapper

    public var label: String {
        switch self {
        case .sessionAgent: "Agent de session"
        case .ephemeralAgent: "Agent temporaire"
        case .wrapper: "Exécutable"
        }
    }
}

/// L'alias SSH saisi ; hôte, utilisateur et port viennent de `ssh -G`, ils ne sont pas stockés
/// `authMode` choisit l'agent de session, un agent temporaire, ou un exécutable ; aucun secret n'est persisté
public struct SSHEndpoint: Equatable, Sendable {
    public var host: String
    public var authMode: SSHAuthMode
    public var wrapperPath: String
    public var keyCommandPath: String

    public init(
        host: String,
        authMode: SSHAuthMode = .sessionAgent,
        wrapperPath: String = "",
        keyCommandPath: String = ""
    ) {
        self.host = host
        self.authMode = authMode
        self.wrapperPath = wrapperPath
        self.keyCommandPath = keyCommandPath
    }

    private enum Key {
        static let host = "ssh.host"
        static let authMode = "ssh.authMode"
        static let wrapperPath = "ssh.wrapperPath"
        static let keyCommandPath = "ssh.keyCommandPath"
    }

    public static func stored(in defaults: UserDefaults) -> SSHEndpoint? {
        guard let host = defaults.string(forKey: Key.host), !host.isEmpty else { return nil }
        let mode = defaults.string(forKey: Key.authMode).flatMap(SSHAuthMode.init(rawValue:)) ?? .sessionAgent
        return SSHEndpoint(
            host: host,
            authMode: mode,
            wrapperPath: defaults.string(forKey: Key.wrapperPath) ?? "",
            keyCommandPath: defaults.string(forKey: Key.keyCommandPath) ?? ""
        )
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(host, forKey: Key.host)
        defaults.set(authMode.rawValue, forKey: Key.authMode)
        defaults.set(wrapperPath, forKey: Key.wrapperPath)
        defaults.set(keyCommandPath, forKey: Key.keyCommandPath)
    }
}
