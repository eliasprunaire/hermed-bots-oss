import HermesAdapter
import SwiftUI
import Textual

/// Rendu Markdown d'une réponse via Textual ; le texte brut n'est qu'un secours
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
                let text = StructuredText(markdown: prepared)
                    .textual.imageAttachmentLoader(InertMarkdownAttachmentLoader())
                    .textual.emojiAttachmentLoader(InertMarkdownAttachmentLoader())
                if selectable {
                    text.textual.textSelection(.enabled)
                } else {
                    text.textual.textSelection(.disabled)
                }
            }
            if streaming {
                Text("▍")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Textual charge par défaut les images Markdown via `URLAttachmentLoader` / `ImageLoader` (hors tunnel)
/// Ce chargeur n'ouvre aucune URL : il rend le texte alternatif
struct InertMarkdownAttachmentLoader: AttachmentLoader {
    func attachment(
        for url: URL,
        text: String,
        environment: ColorEnvironmentValues
    ) async throws -> AltTextAttachment {
        _ = url
        _ = environment
        return AltTextAttachment(text: text)
    }
}

struct AltTextAttachment: Attachment {
    let text: String

    var description: String { text }

    var body: some View {
        Text(text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, in environment: TextEnvironmentValues) -> CGSize {
        _ = environment
        let width = max(1, proposal.width ?? 80)
        let height: CGFloat = text.isEmpty ? 1 : 18
        return CGSize(width: width, height: height)
    }
}
