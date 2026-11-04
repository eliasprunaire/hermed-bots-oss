import Foundation

/// Texte Markdown préparé pour le rendu (Textual) : les délimiteurs ouverts du flux sont fermés.
/// Le texte brut n'est un secours que si le rendu échoue. Les tests lisent `of`, sans étoile restante.
public enum MarkdownVisibleText: Sendable {
    public static func prepared(_ source: String) -> String {
        Walker(source: source).prepared()
    }

    public static func of(_ source: String) -> String {
        Walker(source: prepared(source)).visible()
    }
}

private struct Walker {
    let source: String

    func prepared() -> String {
        var strong = false
        var emphasis = false
        var inlineCode = false
        var fence = false
        var lineStart = true
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if character == "\n" {
                lineStart = true
                index = source.index(after: index)
                continue
            }
            if fence {
                if source[index...].hasPrefix("```") {
                    fence = false
                    index = source.index(index, offsetBy: 3)
                    lineStart = false
                    continue
                }
                lineStart = false
                index = source.index(after: index)
                continue
            }
            if lineStart, source[index...].hasPrefix("```") {
                fence = true
                index = source.index(index, offsetBy: 3)
                lineStart = false
                continue
            }
            if !inlineCode, lineStart, isListMarker(at: index) {
                index = afterListMarker(index)
                lineStart = false
                continue
            }
            lineStart = false
            if character == "`" {
                inlineCode.toggle()
                index = source.index(after: index)
                continue
            }
            if inlineCode {
                index = source.index(after: index)
                continue
            }
            if source[index...].hasPrefix("**") {
                strong.toggle()
                index = source.index(index, offsetBy: 2)
                continue
            }
            if character == "*" {
                emphasis.toggle()
                index = source.index(after: index)
                continue
            }
            index = source.index(after: index)
        }
        var closed = source
        if inlineCode { closed += "`" }
        if strong { closed += "**" }
        if emphasis { closed += "*" }
        return closed
    }

    func visible() -> String {
        var result = ""
        var inlineCode = false
        var fence = false
        var lineStart = true
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if character == "\n" {
                result.append("\n")
                lineStart = true
                index = source.index(after: index)
                continue
            }
            if fence {
                if source[index...].hasPrefix("```") {
                    fence = false
                    index = source.index(index, offsetBy: 3)
                    lineStart = false
                    continue
                }
                result.append(character)
                lineStart = false
                index = source.index(after: index)
                continue
            }
            if lineStart, source[index...].hasPrefix("```") {
                fence = true
                index = source.index(index, offsetBy: 3)
                lineStart = false
                continue
            }
            if !inlineCode, lineStart, isListMarker(at: index) {
                index = afterListMarker(index)
                lineStart = false
                continue
            }
            if lineStart, character == "|" || (result.isEmpty || result.last == "\n"), isAlignmentRow(at: index) {
                index = source[index...].firstIndex(of: "\n") ?? source.endIndex
                continue
            }
            lineStart = false
            if character == "`" {
                inlineCode.toggle()
                index = source.index(after: index)
                continue
            }
            if inlineCode {
                result.append(character)
                index = source.index(after: index)
                continue
            }
            if source[index...].hasPrefix("**") {
                index = source.index(index, offsetBy: 2)
                continue
            }
            if character == "*" {
                index = source.index(after: index)
                continue
            }
            if character == "|" {
                if result.last != " " && result.last != "\n" && !result.isEmpty { result.append(" ") }
                index = source.index(after: index)
                continue
            }
            if character == "#" && (result.isEmpty || result.last == "\n") {
                while index < source.endIndex, source[index] == "#" { index = source.index(after: index) }
                if index < source.endIndex, source[index] == " " { index = source.index(after: index) }
                continue
            }
            result.append(character)
            index = source.index(after: index)
        }
        return result
    }

    func isListMarker(at index: String.Index) -> Bool {
        let rest = source[index...]
        if rest.hasPrefix("* ") || rest.hasPrefix("- ") || rest.hasPrefix("+ ") { return true }
        var digits = 0
        var cursor = index
        while cursor < source.endIndex, source[cursor].isNumber {
            digits += 1
            cursor = source.index(after: cursor)
        }
        return digits > 0 && source[cursor...].hasPrefix(". ")
    }

    func afterListMarker(_ index: String.Index) -> String.Index {
        let rest = source[index...]
        if rest.hasPrefix("* ") || rest.hasPrefix("- ") || rest.hasPrefix("+ ") {
            return source.index(index, offsetBy: 2)
        }
        var cursor = index
        while cursor < source.endIndex, source[cursor].isNumber { cursor = source.index(after: cursor) }
        return source.index(cursor, offsetBy: 2)
    }

    func isAlignmentRow(at index: String.Index) -> Bool {
        let line = source[index...].prefix { $0 != "\n" }
        let cells = line.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        return !cells.isEmpty && cells.allSatisfy { cell in
            cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }
}
