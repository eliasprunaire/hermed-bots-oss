import Foundation

/// Seuils de compaction d'Hermes Agent : compressor maison vers 50 %, compression passerelle vers 85 %.
public struct ContextCompaction: Equatable, Sendable {
    public static let compressorRatio = 0.50
    public static let gatewayRatio = 0.85
    /// Fenêtre par défaut quand Hermes ne donne pas le budget (128 k tokens, docs Hermes Agent).
    public static let defaultWindowTokens = 128_000

    public var usedTokens: Int
    public var windowTokens: Int

    public init(usedTokens: Int, windowTokens: Int = ContextCompaction.defaultWindowTokens) {
        self.usedTokens = max(0, usedTokens)
        self.windowTokens = max(1, windowTokens)
    }

    public var ratio: Double { min(1, Double(usedTokens) / Double(windowTokens)) }

    /// Pourcentage entier, borné 0…100, pour le pied de page.
    public var percent: Int { min(100, Int((ratio * 100).rounded(.down))) }

    /// Le compressor Hermes a dû résumer les tours anciens.
    public var isCompacted: Bool { ratio >= Self.compressorRatio }

    /// La passerelle a compressé le contexte (seuil haut).
    public var isGatewayCompressed: Bool { ratio >= Self.gatewayRatio }

    /// Estimation naïve : ~4 octets UTF-8 par token, comme le budget côté client.
    public static func estimateTokens(_ text: String) -> Int {
        (text.utf8.count + 3) / 4
    }

    public static func of(transcript: String, windowTokens: Int = defaultWindowTokens) -> ContextCompaction {
        ContextCompaction(usedTokens: estimateTokens(transcript), windowTokens: windowTokens)
    }
}
