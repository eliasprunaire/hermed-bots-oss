import Foundation

public enum SSHExitKind: String, Sendable, Equatable {
    case hostUnreachable
    case authRefused
    case agentUnavailable
    case agentEmpty
    case missingKey
    case tunnelClosed
    case certificateExpired
    case hostKeyChanged
    case wrapperFailure
}

/// Une ligne `<nom>_failure=<code>` écrite par un exécutable SSH personnalisé sur sa sortie d'erreur
public struct SSHWrapperFailure: Sendable, Equatable {
    public let name: String
    public let code: String

    public init(name: String, code: String) {
        self.name = name
        self.code = code
    }
}

public struct SSHExitClassification: Sendable, Equatable {
    public let stage: String
    public let fallback: SSHExitKind
    public let reason: String

    public static let sshStage = "ssh"
    public static let hermesUnreachableMessage = "la machine Hermes ne répond pas"

    public init(stage: String, fallback: SSHExitKind, reason: String) {
        self.stage = stage
        self.fallback = fallback
        self.reason = reason
    }

    public static func make(stderr: String, status: Int32, timedOut: Bool = false) -> SSHExitClassification {
        if timedOut {
            return SSHExitClassification(stage: sshStage, fallback: .hostUnreachable, reason: "timeout")
        }
        let kind = kind(stderr: stderr, status: status)
        return SSHExitClassification(
            stage: stageName(kind),
            fallback: kind,
            reason: reasonName(kind, status: status)
        )
    }

    /// Texte affiché pour un SSH injoignable (code 255) ou un délai dépassé ; nil sinon
    public var displayedMessage: String? {
        guard stage == Self.sshStage, fallback == .hostUnreachable else { return nil }
        if reason == "timeout" || reason == "exit-255" {
            return Self.hermesUnreachableMessage
        }
        return nil
    }

    private static func stageName(_ kind: SSHExitKind) -> String {
        switch kind {
        case .wrapperFailure: return "wrapper"
        case .tunnelClosed: return "tunnel"
        default: return sshStage
        }
    }

    private static func reasonName(_ kind: SSHExitKind, status: Int32) -> String {
        if kind == .hostUnreachable { return "exit-\(status)" }
        return kind.rawValue
    }

    public static func kind(stderr: String, status: Int32) -> SSHExitKind {
        let text = stderr
        // l'exécutable a nommé lui-même son échec : cette ligne l'emporte sur les phrases d'OpenSSH
        if wrapperFailure(stderr: text) != nil { return .wrapperFailure }
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

    private static let wrapperMarker = "_failure="

    /// Premier mot `<nom>_failure=<code>` de la sortie d'erreur : le nom et le code sont bornés et sans caractère exotique, car l'app les affiche
    public static func wrapperFailure(stderr: String) -> SSHWrapperFailure? {
        guard stderr.contains(wrapperMarker) else { return nil }
        for word in stderr.split(whereSeparator: { $0.isWhitespace }) {
            guard let marker = word.range(of: wrapperMarker) else { continue }
            let name = word[..<marker.lowerBound]
            let code = word[marker.upperBound...]
            guard (1...64).contains(name.count), name.first?.isASCIILetterOrDigit == true,
                  name.allSatisfy({ $0.isASCIILetterOrDigit || "._-".contains($0) }),
                  (1...32).contains(code.count),
                  code.allSatisfy({ $0.isASCIILetterOrDigit || "._:-".contains($0) }) else { continue }
            return SSHWrapperFailure(name: String(name), code: String(code))
        }
        return nil
    }

    private static func closedByPeer(_ text: String) -> Bool {
        let folded = text.lowercased()
        return folded.contains("connection reset by peer")
            || folded.contains("closed by remote host")
            || folded.contains("connection closed by")
    }
}

private extension Character {
    var isASCIILetterOrDigit: Bool { isASCII && (isLetter || isNumber) }
}
