import Foundation

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
