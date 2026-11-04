import Foundation

/// Document Markdown réduit : titres, listes, tableaux GFM, blocs de code, gras et italique.
/// Les marqueurs (`**`, `|`, clôtures) ne restent pas dans le texte visible.
public struct MarkdownDocument: Equatable, Sendable {
    public enum Inline: Equatable, Sendable {
        case text(String)
        case strong(String)
        case emphasis(String)
        case code(String)
    }

    public enum Block: Equatable, Sendable {
        case heading(level: Int, text: [Inline])
        case paragraph([Inline])
        case list(items: [[Inline]], ordered: Bool)
        case table(header: [String], rows: [[String]])
        case code(String)
    }

    public var blocks: [Block]

    public init(blocks: [Block]) {
        self.blocks = blocks
    }

    public static func parse(_ source: String) -> MarkdownDocument {
        var parser = Parser(source)
        return MarkdownDocument(blocks: parser.parse())
    }

    /// Texte montré à l'écran, sans marqueurs Markdown.
    public var visibleText: String {
        blocks.map(\.visibleText).joined(separator: "\n")
    }

    public var hasTable: Bool { blocks.contains { if case .table = $0 { return true }; return false } }
    public var hasCodeBlock: Bool { blocks.contains { if case .code = $0 { return true }; return false } }
}

extension MarkdownDocument.Block {
    var visibleText: String {
        switch self {
        case .heading(_, let text), .paragraph(let text):
            return MarkdownDocument.visible(text)
        case .list(let items, _):
            return items.map { MarkdownDocument.visible($0) }.joined(separator: "\n")
        case .table(let header, let rows):
            return (header + rows.flatMap { $0 }).joined(separator: " ")
        case .code(let code):
            return code
        }
    }
}

extension MarkdownDocument {
    public static func visible(_ inlines: [Inline]) -> String {
        inlines.map {
            switch $0 {
            case .text(let value), .strong(let value), .emphasis(let value), .code(let value):
                return value
            }
        }.joined()
    }
}

private struct Parser {
    let lines: [Substring]
    var index = 0

    init(_ source: String) {
        lines = source.split(separator: "\n", omittingEmptySubsequences: false)
    }

    mutating func parse() -> [MarkdownDocument.Block] {
        var blocks: [MarkdownDocument.Block] = []
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("```") {
                blocks.append(.code(readFence()))
                continue
            }
            if isTableStart() {
                if let table = readTable() { blocks.append(table) }
                continue
            }
            if let heading = heading(line) {
                blocks.append(heading)
                index += 1
                continue
            }
            if let item = listItem(line) {
                blocks.append(readList(first: item))
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }
            blocks.append(.paragraph(inlines(String(line))))
            index += 1
        }
        return blocks
    }

    mutating func readFence() -> String {
        index += 1
        var body: [String] = []
        while index < lines.count {
            let line = lines[index]
            index += 1
            if line.hasPrefix("```") { break }
            body.append(String(line))
        }
        return body.joined(separator: "\n")
    }

    func isTableStart() -> Bool {
        guard index + 1 < lines.count else { return false }
        return lines[index].contains("|") && isAlignmentRow(lines[index + 1])
    }

    func isAlignmentRow(_ line: Substring) -> Bool {
        let cells = splitRow(line)
        return !cells.isEmpty && cells.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && trimmed.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    mutating func readTable() -> MarkdownDocument.Block? {
        let header = splitRow(lines[index])
        index += 2
        var rows: [[String]] = []
        while index < lines.count, lines[index].contains("|"), !isAlignmentRow(lines[index]) {
            rows.append(splitRow(lines[index]))
            index += 1
        }
        return .table(header: header, rows: rows)
    }

    func splitRow(_ line: Substring) -> [String] {
        var raw = line.trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("|") { raw.removeFirst() }
        if raw.hasSuffix("|") { raw.removeLast() }
        return raw.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    func heading(_ line: Substring) -> MarkdownDocument.Block? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        var level = 0
        for character in trimmed {
            if character == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level), trimmed.dropFirst(level).first == " " else { return nil }
        return .heading(level: level, text: inlines(String(trimmed.dropFirst(level + 1))))
    }

    func listItem(_ line: Substring) -> (ordered: Bool, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return (false, String(trimmed.dropFirst(2)))
        }
        var digits = 0
        for character in trimmed {
            if character.isNumber { digits += 1 } else { break }
        }
        guard digits > 0, trimmed.dropFirst(digits).hasPrefix(". ") else { return nil }
        return (true, String(trimmed.dropFirst(digits + 2)))
    }

    mutating func readList(first: (ordered: Bool, text: String)) -> MarkdownDocument.Block {
        var items = [inlines(first.text)]
        index += 1
        while index < lines.count, let item = listItem(lines[index]), item.ordered == first.ordered {
            items.append(inlines(item.text))
            index += 1
        }
        return .list(items: items, ordered: first.ordered)
    }

    func inlines(_ text: String) -> [MarkdownDocument.Inline] {
        var result: [MarkdownDocument.Inline] = []
        var rest = text[...]
        while !rest.isEmpty {
            if rest.hasPrefix("`") {
                rest.removeFirst()
                if let end = rest.firstIndex(of: "`") {
                    result.append(.code(String(rest[..<end])))
                    rest = rest[rest.index(after: end)...]
                    continue
                }
                result.append(.text("`"))
                continue
            }
            if rest.hasPrefix("**") {
                rest.removeFirst(2)
                if let range = rest.range(of: "**") {
                    result.append(.strong(String(rest[..<range.lowerBound])))
                    rest = rest[range.upperBound...]
                    continue
                }
                result.append(.text("**"))
                continue
            }
            if rest.hasPrefix("*") {
                rest.removeFirst()
                if let end = rest.firstIndex(of: "*") {
                    result.append(.emphasis(String(rest[..<end])))
                    rest = rest[rest.index(after: end)...]
                    continue
                }
                result.append(.text("*"))
                continue
            }
            var buffer = ""
            while let first = rest.first, first != "`", first != "*" {
                buffer.append(first)
                rest.removeFirst()
            }
            if !buffer.isEmpty { result.append(.text(buffer)) }
        }
        return result.isEmpty ? [.text(text)] : result
    }
}
