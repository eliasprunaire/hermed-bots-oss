import Foundation

/// L'alias SSH saisi ; hôte, utilisateur et port viennent de `ssh -G`, ils ne sont pas stockés
public struct SSHEndpoint: Equatable, Sendable {
    public var host: String

    public init(host: String) {
        self.host = host
    }

    private enum Key {
        static let host = "ssh.host"
    }

    public static func stored(in defaults: UserDefaults) -> SSHEndpoint? {
        guard let host = defaults.string(forKey: Key.host), !host.isEmpty else { return nil }
        return SSHEndpoint(host: host)
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(host, forKey: Key.host)
    }
}
