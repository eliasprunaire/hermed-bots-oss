import Foundation

/// Picks the SSH mode when the user has not chosen one in the picker.
public enum SSHAuthModeChoice: Sendable {
    public static func selected(
        userChose: Bool,
        stored: SSHAuthMode,
        keyCommandSet: Bool,
        hasExternalIdentityAgent: Bool
    ) -> SSHAuthMode {
        if userChose { return stored }
        if stored == .wrapper { return stored }
        if stored == .ephemeralAgent && keyCommandSet { return stored }
        return hasExternalIdentityAgent ? .ephemeralAgent : .sessionAgent
    }
}
