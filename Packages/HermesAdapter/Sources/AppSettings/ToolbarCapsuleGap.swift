/// Écart entre « Tout arrêter » et « Nouvelle session » dans la barre d'outils.
/// Les deux boutons sont des `ToolbarItem` distincts : l'espacement natif de la barre
/// a été relevé à 7 pt (14 px @2x) sur les captures clair/sombre × standard/large.
/// Le padding d'appoint porte l'écart rendu à `points`, identique dans les quatre cas.
public enum ToolbarCapsuleGap {
    /// 26 px mesurés en clair sur capture @2x : valeur retenue
    public static let points = 13.0
    /// 14 px entre les capsules sur les captures @2x
    public static let nativeToolbarSpacing = 7.0

    public static func resolved(dark: Bool, largeText: Bool) -> Double {
        points
    }

    public static func extraLeadingPadding(dark: Bool, largeText: Bool) -> Double {
        resolved(dark: dark, largeText: largeText) - nativeToolbarSpacing
    }
}
