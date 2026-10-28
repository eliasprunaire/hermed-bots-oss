import Foundation

/// Port SSH montré en lecture seule : celui de `ssh -G`, ou 22 si cette lecture échoue
public struct SSHDisplayedPort: Equatable, Sendable {
    public static let fallback = 22

    public let number: Int
    public let fromSSHConfig: Bool

    public var settingsTitle: String {
        fromSSHConfig ? "Port (config SSH)" : "Port"
    }

    public var settingsValue: String { String(number) }

    public var statusText: String {
        fromSSHConfig ? "Port SSH \(number) (config SSH)" : "Port SSH \(number)"
    }

    /// `resolvedPort` est le champ `port` d'un dump `ssh -G` réussi. `nil` : la résolution a échoué, on garde 22.
    public static func readOnly(resolvedPort: Int?) -> SSHDisplayedPort {
        guard let resolvedPort else {
            return SSHDisplayedPort(number: fallback, fromSSHConfig: false)
        }
        return SSHDisplayedPort(number: resolvedPort, fromSSHConfig: true)
    }
}
