import Foundation

public struct SSHEndpoint: Equatable, Sendable {
    public var host: String
    public var user: String
    public var port: Int

    public init(host: String, user: String, port: Int) {
        self.host = host
        self.user = user
        self.port = port
    }

    private enum Key {
        static let host = "ssh.host"
        static let user = "ssh.user"
        static let port = "ssh.port"
    }

    public static func stored(in defaults: UserDefaults) -> SSHEndpoint? {
        guard let host = defaults.string(forKey: Key.host), !host.isEmpty else { return nil }
        let port = defaults.integer(forKey: Key.port)
        return SSHEndpoint(host: host, user: defaults.string(forKey: Key.user) ?? NSUserName(), port: port == 0 ? 22 : port)
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(host, forKey: Key.host)
        defaults.set(user, forKey: Key.user)
        defaults.set(port, forKey: Key.port)
    }
}
