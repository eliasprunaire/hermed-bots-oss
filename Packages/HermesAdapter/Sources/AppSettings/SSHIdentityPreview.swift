import Foundation

/// Kind shown in Connexion after overlaying the selected SSH mode on a session dump.
public enum SSHLaunchIdentityKind: String, Sendable, Equatable {
    case agent
    case certificate
    case file
}

/// Identité Connect will use. Session `ssh -G` can list default files while ephemeral mode uses an agent.
public struct SSHLaunchIdentity: Equatable, Sendable {
    public var kind: SSHLaunchIdentityKind
    public var present: Bool

    public init(kind: SSHLaunchIdentityKind, present: Bool) {
        self.kind = kind
        self.present = present
    }

    /// `identityagent` is external when it is set, not `none`, and not only `SSH_AUTH_SOCK`.
    public static func identityAgentIsExternal(_ value: String?) -> Bool {
        guard let value else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if trimmed.caseInsensitiveCompare("none") == .orderedSame { return false }
        if trimmed == "SSH_AUTH_SOCK" { return false }
        return true
    }

    public static func overlay(
        mode: SSHAuthMode,
        sessionKind: SSHLaunchIdentityKind,
        sessionPresent: Bool,
        keyCommandSet: Bool,
        hasExternalIdentityAgent: Bool
    ) -> SSHLaunchIdentity {
        switch mode {
        case .sessionAgent, .wrapper:
            return SSHLaunchIdentity(kind: sessionKind, present: sessionPresent)
        case .ephemeralAgent:
            return SSHLaunchIdentity(kind: .agent, present: keyCommandSet || hasExternalIdentityAgent)
        }
    }
}
