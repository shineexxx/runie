import Foundation

/// Блок разметки ответа: абзац, заголовок, пункт списка, код, цитата, таблица, черта.
///
/// Разбор построчный и прощающий: ответ приходит по кусочку, и незакрытый блок кода
/// в середине печати — нормальное состояние, а не ошибка. Строчная разметка
/// (жирный, ссылки) внутри текста остаётся как есть — её разбирает интерфейс.
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    /// Пункт списка. `marker` — «•» или «3.», `level` — вложенность от нуля.
    case listItem(level: Int, marker: String, text: String)
    case code(language: String?, text: String)
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule

    public static func parse(_ source: String) -> [MarkdownBlock] {
        var parser = Parser(lines: source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"))
        return parser.run()
    }
}

private struct Parser {
    let lines: [String]
    var index = 0
    var blocks: [MarkdownBlock] = []
    var paragraph: [String] = []

    init(lines: [String]) {
        self.lines = lines
    }

    mutating func run() -> [MarkdownBlock] {
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
            } else if let fence = Self.fence(trimmed) {
                flushParagraph()
                readCode(fence: fence)
            } else if let heading = Self.heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
            } else if Self.isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                readQuote()
            } else if trimmed.hasPrefix("|"), index + 1 < lines.count, Self.isTableSeparator(lines[index + 1]) {
                flushParagraph()
                readTable()
            } else if let item = Self.listItem(line) {
                flushParagraph()
                blocks.append(item)
                index += 1
                // Продолжение пункта — строки с отступом, которые сами не пункт.
                while index < lines.count {
                    let next = lines[index]
                    let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                    guard !nextTrimmed.isEmpty, next.first == " " || next.first == "\t",
                          Self.listItem(next) == nil, Self.fence(nextTrimmed) == nil,
                          case .listItem(let level, let marker, let text) = blocks.last
                    else { break }
                    blocks[blocks.count - 1] = .listItem(level: level, marker: marker, text: text + "\n" + nextTrimmed)
                    index += 1
                }
            } else {
                paragraph.append(trimmed)
                index += 1
            }
        }
        flushParagraph()
        return blocks
    }

    mutating func flushParagraph() {
        guard !paragraph.isEmpty else { return }
        blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        paragraph.removeAll()
    }

    mutating func readCode(fence: (marker: String, language: String?)) {
        index += 1
        var body: [String] = []
        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence.marker) {
                index += 1
                break
            }
            body.append(lines[index])
            index += 1
        }
        blocks.append(.code(language: fence.language, text: body.joined(separator: "\n")))
    }

    mutating func readQuote() {
        var body: [String] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            body.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            index += 1
        }
        blocks.append(.quote(body.joined(separator: "\n")))
    }

    mutating func readTable() {
        let header = Self.cells(lines[index])
        index += 2
        var rows: [[String]] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|") else { break }
            var row = Self.cells(trimmed)
            // Ряд подгоняется под шапку: лишние ячейки отбрасываются, недостающие пусты.
            if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
            rows.append(Array(row.prefix(header.count)))
            index += 1
        }
        blocks.append(.table(header: header, rows: rows))
    }

    // MARK: Распознавание строк

    static func fence(_ trimmed: String) -> (marker: String, language: String?)? {
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
            let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
            return (marker, language.isEmpty ? nil : language)
        }
        return nil
    }

    static func heading(_ trimmed: String) -> MarkdownBlock? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
        return .heading(level: hashes, text: text)
    }

    static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func listItem(_ line: String) -> MarkdownBlock? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let body = line.drop { $0 == " " || $0 == "\t" }
        let level = min(indent / 2, 4)

        if let first = body.first, "-*+•".contains(first), body.dropFirst().first == " " {
            let text = body.dropFirst(2).trimmingCharacters(in: .whitespaces)
            // Задача с галочкой — тоже пункт, отмеченный символом.
            if text.hasPrefix("[ ] ") { return .listItem(level: level, marker: "☐", text: String(text.dropFirst(4))) }
            if text.lowercased().hasPrefix("[x] ") { return .listItem(level: level, marker: "☑", text: String(text.dropFirst(4))) }
            return .listItem(level: level, marker: "•", text: text)
        }
        let digits = body.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let after = body.dropFirst(digits.count)
        guard let punct = after.first, punct == "." || punct == ")", after.dropFirst().first == " " else { return nil }
        return .listItem(level: level, marker: digits + ".", text: after.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.hasPrefix("|") || trimmed.hasPrefix(":") || trimmed.hasPrefix("-") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) }
    }

    static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
