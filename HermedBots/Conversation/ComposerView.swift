import HermesAdapter
import SwiftUI

/// Le champ de saisie et le bouton Envoyer, dans une capsule de verre qui flotte au-dessus du fil
/// Envoyer est grisé pour un brouillon vide ou fait de blancs, et pendant un tour ; ⏎ passe par la même garde que le bouton
/// ⏎ refuse pendant un tour : SwiftUI lâche le focus et AppKit sélectionne le brouillon (sélection inactive grise) ; `submit` le rend et pose le caret à la fin
struct ComposerView: View {
    @Bindable var model: ConversationModel
    let bot: Bot
    @FocusState private var focused: Bool
    @Environment(\.hideComposerCaret) private var hideComposerCaret
    @State private var submitGeneration = 0

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(composerPrompt, text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($focused)
                .disabled(model.isOpening || model.openError != nil)
                .overlay(alignment: .leading) {
                    if !model.draft.isEmpty, Conversation.message(from: model.draft) == nil {
                        Text(composerPrompt)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.vertical, 7)
                .onSubmit(submit)
                .background(ComposerSubmitRepair(generation: submitGeneration))
                .modifier(ComposerCaretTint(hidden: hideComposerCaret))
                .accessibilityID(.composerInput)
            Button(action: model.send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(model.canSend ? AnyShapeStyle(Palette.gradient(Palette.colors(bot))) : AnyShapeStyle(.quaternary), in: .circle)
            }
            .buttonStyle(PressStyle())
            .disabled(!model.canSend)
            .help("Envoyer")
            .accessibilityLabel("Envoyer")
            .accessibilityID(.composerSend)
        }
        .padding(.leading, 16)
        .padding(.trailing, 7)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .column()
        .padding(.top, 6)
        .padding(.bottom, 14)
        .onAppear { focused = true }
    }

    private var composerPrompt: String {
        model.openError == nil ? "Écrire à \(bot.name)…" : model.composerUnavailableText
    }

    /// Même garde que le bouton, puis focus et caret à la fin : un ⏎ refusé ne laisse pas de sélection
    private func submit() {
        model.send()
        focused = true
        submitGeneration += 1
    }
}

/// Position du caret après ⏎ : fin du brouillon, aucune étendue
enum ComposerSubmit {
    static func collapsedRange(of text: String) -> NSRange {
        NSRange(location: (text as NSString).length, length: 0)
    }
}

/// Replace le premier répondant sur l'éditeur éditable du champ, sans toucher aux bulles du fil
private struct ComposerSubmitRepair: NSViewRepresentable {
    var generation: Int

    final class Coordinator {
        var applied = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.isHidden = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard generation != context.coordinator.applied else { return }
        context.coordinator.applied = generation
        guard generation > 0 else { return }
        DispatchQueue.main.async { Self.restore(from: view) }
    }

    private static func restore(from probe: NSView) {
        guard let editor = fieldEditor(near: probe) else { return }
        editor.window?.makeFirstResponder(editor)
        editor.setSelectedRange(ComposerSubmit.collapsedRange(of: editor.string))
    }

    private static func fieldEditor(near probe: NSView) -> NSTextView? {
        var node: NSView? = probe
        for _ in 0..<12 {
            guard let current = node else { break }
            if let editor = editableTextView(in: current) { return editor }
            node = current.superview
        }
        return (probe.window?.firstResponder as? NSTextView).flatMap { $0.isEditable ? $0 : nil }
    }

    private static func editableTextView(in view: NSView) -> NSTextView? {
        if let editor = view as? NSTextView, editor.isEditable { return editor }
        for child in view.subviews {
            if let editor = editableTextView(in: child) { return editor }
        }
        return nil
    }
}

/// Mode test seulement : `tint(.clear)` rend le caret invisible sans retirer le focus ni fermer une feuille
private struct ComposerCaretTint: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        if hidden {
            content.tint(.clear)
        } else {
            content
        }
    }
}
