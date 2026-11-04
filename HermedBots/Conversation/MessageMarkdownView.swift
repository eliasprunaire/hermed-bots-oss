import HermesAdapter
import SwiftUI
import Textual

/// Rendu Markdown d'une réponse via Textual ; le texte brut n'est qu'un secours.
struct MessageMarkdownView: View {
    let source: String
    var selectable: Bool
    var streaming: Bool

    var body: some View {
        let prepared = MarkdownVisibleText.prepared(source)
        VStack(alignment: .leading, spacing: 8) {
            if prepared.isEmpty {
                EmptyView()
            } else {
                StructuredText(markdown: prepared)
                    .textual.textSelection(selectable ? .enabled : .disabled)
            }
            if streaming {
                Text("▍")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }
}
