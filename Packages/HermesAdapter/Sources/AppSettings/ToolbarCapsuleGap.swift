/// Écart entre « Tout arrêter » et « Nouvelle session » dans la barre d'outils.
/// Les deux boutons sont des `ToolbarItem` distincts : l'espacement natif de la barre
/// a été relevé à 7 pt (14 px @2x) sur les captures clair/sombre × standard/large.
/// Un spacer de conteneur, hors du verre de la capsule, porte l'écart rendu à `points`.
/// Un padding interne agrandit la capsule et laisse l'espace libre à 7 pt.
public enum ToolbarCapsuleGap {
    /// 26 px mesurés en clair sur capture @2x : valeur retenue
    public static let points = 13.0
    /// 14 px entre les capsules sur les captures @2x
    public static let nativeToolbarSpacing = 7.0
    /// Captures `piste1-empty-conversation-*` : 1 pt = 2 px
    public static let captureScale = 2.0

    public static func resolved(dark: Bool, largeText: Bool) -> Double {
        points
    }

    public static func extraContainerSpacing(dark: Bool, largeText: Bool) -> Double {
        resolved(dark: dark, largeText: largeText) - nativeToolbarSpacing
    }

    public static func freePixels(dark: Bool, largeText: Bool) -> Double {
        resolved(dark: dark, largeText: largeText) * captureScale
    }
}
