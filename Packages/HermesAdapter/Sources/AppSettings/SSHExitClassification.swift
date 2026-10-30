import Foundation

/// Outcome of a failed ssh, from stderr and the process status. No host, path, or key.
public enum SSHExitKind: String, Sendable, Equatable {
    case hostUnreachable
    case authRefused
    case agentUnavailable
    case agentEmpty
    case missingKey
    case tunnelClosed
    case certificateExpired
    case hostKeyChanged
}

public enum SSHExitClassification: Sendable {
    public static func kind(stderr: String, status: Int32) -> SSHExitKind {
        let text = stderr
        if text.contains("Could not open a connection to your authentication agent")
            || text.contains("Error connecting to agent") {
            return .agentUnavailable
        }
        if text.contains("The agent has no identities") {
            return .missingKey
        }
        if text.localizedCaseInsensitiveContains("agent refused operation") {
            return .agentEmpty
        }
        if text.localizedCaseInsensitiveContains("certificate invalid")
            || text.localizedCaseInsensitiveContains("certificate expired")
            || text.localizedCaseInsensitiveContains("certificate has expired") {
            return .certificateExpired
        }
        if text.contains("Permission denied") {
            return .authRefused
        }
        if text.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || text.contains("Host key verification failed") {
            return .hostKeyChanged
        }
        if closedByPeer(text) {
            return .tunnelClosed
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return status == 255 ? .hostUnreachable : .tunnelClosed
        }
        return .hostUnreachable
    }

    private static func closedByPeer(_ text: String) -> Bool {
        let folded = text.lowercased()
        return folded.contains("connection reset by peer")
            || folded.contains("closed by remote host")
            || folded.contains("connection closed by")
    }
}
