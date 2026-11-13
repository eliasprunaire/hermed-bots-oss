import Foundation

/// Position du caret après ⏎ : fin du brouillon, aucune étendue
enum ComposerSubmit {
    static func collapsedRange(of text: String) -> NSRange {
        NSRange(location: (text as NSString).length, length: 0)
    }
}
