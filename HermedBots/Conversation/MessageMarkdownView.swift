import HermesAdapter
import SwiftUI

/// Rendu Markdown d'une réponse : titres, listes, tableaux, code, sans marqueurs bruts.
struct MessageMarkdownView: View {
    let source: String
    var selectable: Bool
    var streaming: Bool

    var body: some View {
        let document = MarkdownDocument.parse(source)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
            if streaming {
                Text("▍")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .textSelection(selectable ? .enabled : .disabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownDocument.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text).font(headingFont(level)).fontWeight(.semibold)
        case .paragraph(let text):
            inlineText(text)
        case .list(let items, let ordered):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(index + 1)." : "•")
                        inlineText(item)
                    }
                }
            }
        case .table(let header, let rows):
            MarkdownTableView(header: header, rows: rows)
        case .code(let code):
            Text(verbatim: code)
                .font(.body.monospaced())
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2
        case 2: .title3
        default: .headline
        }
    }

    private func inlineText(_ inlines: [MarkdownDocument.Inline]) -> Text {
        inlines.reduce(Text(verbatim: "")) { result, part in
            switch part {
            case .text(let value): result + Text(verbatim: value)
            case .strong(let value): result + Text(verbatim: value).bold()
            case .emphasis(let value): result + Text(verbatim: value).italic()
            case .code(let value): result + Text(verbatim: value).font(.body.monospaced())
            }
        }
    }
}

private struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    Text(verbatim: cell).fontWeight(.semibold)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(verbatim: cell)
                    }
                }
            }
        }
        .font(.callout)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
    }
}
