import AppKit

/// Réduit la sélection des champs éditables à un point d'insertion, sans toucher au premier répondant
/// Mode test : `HVShot` demande cette réduction juste avant chaque capture, et ferme les info-bulles ouvertes
@MainActor
enum CaptureSelection {
    static let requestName = Notification.Name("com.hermedbots.hv.collapse-selection")
    static let doneName = Notification.Name("com.hermedbots.hv.collapse-selection.done")

    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: requestName, object: nil, queue: .main) { _ in
            Task { @MainActor in
                collapseOpenEditors()
                dismissOpenToolTips()
                DistributedNotificationCenter.default().postNotificationName(
                    doneName, object: nil, userInfo: nil, deliverImmediately: true
                )
            }
        }
    }

    static func apply(to editor: NSText) {
        editor.selectedRange = ComposerSubmit.collapsedRange(of: editor.string)
    }

    static func collapseOpenEditors() {
        for window in NSApp.windows {
            if let editor = window.firstResponder as? NSText {
                apply(to: editor)
            }
            if let editor = window.fieldEditor(false, for: nil) {
                apply(to: editor)
            }
            if let view = window.contentView {
                collapse(in: view)
            }
        }
    }

    private static func collapse(in view: NSView) {
        if let editor = view as? NSTextView, editor.isEditable {
            apply(to: editor)
        }
        if let field = view as? NSTextField, let editor = field.currentEditor() {
            apply(to: editor)
        }
        for child in view.subviews {
            collapse(in: child)
        }
    }

    /// Panneau AppKit `NSToolTipPanel` : le refermer ne touche ni au focus ni à l'état affiché
    static func isTooltipWindow(_ window: NSWindow) -> Bool {
        NSStringFromClass(type(of: window)).localizedCaseInsensitiveContains("tooltip")
    }

    static func dismissOpenToolTips() {
        for window in NSApp.windows where isTooltipWindow(window) {
            window.orderOut(nil)
        }
    }

    /// Point fenêtre : milieu du haut, hors des contrôles `.help` du contenu
    static func neutralPoint(in window: NSWindow) -> NSPoint {
        NSPoint(x: window.frame.width / 2, y: window.frame.height - 8)
    }

    static func helpTag(at pointInWindow: NSPoint, in window: NSWindow) -> String? {
        guard let content = window.contentView else { return nil }
        let pointInView = content.convert(pointInWindow, from: nil)
        var node = content.hitTest(pointInView)
        while let view = node {
            if let tip = view.toolTip, !tip.isEmpty { return tip }
            node = view.superview
        }
        return nil
    }
}
