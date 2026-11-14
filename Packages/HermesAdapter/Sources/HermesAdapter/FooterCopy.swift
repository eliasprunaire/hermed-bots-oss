import Foundation

/// Texte du pied de fenêtre : un seul espace entre les segments, aucun en bord.
public enum FooterCopy {
    public static func line(_ segments: String...) -> String {
        segments
            .flatMap { $0.split(whereSeparator: \.isWhitespace) }
            .joined(separator: " ")
    }
}
