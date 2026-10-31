import Foundation

public enum SSHLaunchIdentityKind: String, Sendable, Equatable {
    case agent
    case certificate
    case file
    /// Mode Exécutable : l'exécutable choisit l'identité, l'app n'en lit aucune
    case executable
}

public struct SSHLaunchIdentity: Equatable, Sendable {
    public var kind: SSHLaunchIdentityKind
    public var present: Bool

    public init(kind: SSHLaunchIdentityKind, present: Bool) {
        self.kind = kind
        self.present = present
    }

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
        case .sessionAgent:
            return SSHLaunchIdentity(kind: sessionKind, present: sessionPresent)
        case .wrapper:
            return SSHLaunchIdentity(kind: .executable, present: true)
        case .ephemeralAgent:
            return SSHLaunchIdentity(kind: .agent, present: keyCommandSet || hasExternalIdentityAgent)
        }
    }

    public static func overlayMode(picker: SSHAuthMode, launch: SSHAuthMode?) -> SSHAuthMode {
        launch ?? picker
    }

    public static func allows(_ kind: SSHLaunchIdentityKind, launch: SSHAuthMode?) -> Bool {
        guard let launch else { return true }
        switch launch {
        case .ephemeralAgent:
            return kind == .agent
        case .sessionAgent, .wrapper:
            return true
        }
    }
}
