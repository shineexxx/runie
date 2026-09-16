import Foundation

/// Картинка или файл, приложенные к сообщению.
public struct Attachment: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    /// Абсолютный путь. Снимки экрана и картинки лежат в папке Runie, остальные
    /// файлы — там, где были.
    public let path: String
    public let name: String

    public init(id: UUID = UUID(), path: String, name: String? = nil) {
        self.id = id
        self.path = path
        self.name = name ?? (path as NSString).lastPathComponent
    }

    public var url: URL { URL(fileURLWithPath: path) }

    /// Модель увидит картинку, а не только путь.
    public var isImage: Bool {
        MessageImage.mediaType(forExtension: url.pathExtension) != nil
    }

    /// Приписка к сообщению для агента: где лежат приложенные файлы.
    static func agentNote(for attachments: [Attachment]) -> String {
        guard !attachments.isEmpty else { return "" }
        let lines = attachments.map { attachment in
            attachment.isImage
                ? "- картинка (показана выше): \(attachment.path)"
                : "- файл: \(attachment.path)"
        }
        return "\n\n[Приложено пользователем:\n" + lines.joined(separator: "\n") + "]"
    }
}

/// Ответ агента, разобранный на текст, картинки и файлы.
///
/// Руни показывает картинку, если агент вставил её как в Markdown:
/// `![описание](путь или ссылка)`, а файл — ссылкой на локальный путь:
/// `[отчёт.pdf](/Users/…/отчёт.pdf)`. Ссылки на сайты остаются текстом.
public enum MessageSegment: Sendable, Equatable {
    case text(String)
    case image(source: String, alt: String)
    case file(path: String, name: String)

    public static func parse(_ text: String) -> [MessageSegment] {
        var segments: [MessageSegment] = []
        var buffer = ""
        var index = text.startIndex

        func flush() {
            let trimmed = buffer.trimmingCharacters(in: .newlines)
            if !trimmed.isEmpty { segments.append(.text(trimmed)) }
            buffer = ""
        }

        while index < text.endIndex {
            let isImage = text[index] == "!" && text.index(after: index) < text.endIndex
                && text[text.index(after: index)] == "["
            let isLink = text[index] == "["
            if isImage || isLink,
               let match = link(in: text, at: isImage ? text.index(after: index) : index) {
                let target = match.target
                if isImage {
                    flush()
                    segments.append(.image(source: expand(target), alt: match.label))
                    index = match.end
                    continue
                }
                if isLocalPath(target) {
                    flush()
                    let path = expand(target)
                    let name = match.label.isEmpty ? (path as NSString).lastPathComponent : match.label
                    segments.append(.file(path: path, name: name))
                    index = match.end
                    continue
                }
            }
            buffer.append(text[index])
            index = text.index(after: index)
        }
        flush()
        return segments
    }

    /// `[подпись](цель)` начиная с `[`.
    private static func link(in text: String, at start: String.Index) -> (label: String, target: String, end: String.Index)? {
        guard text[start] == "[", let close = text[start...].firstIndex(of: "]") else { return nil }
        let open = text.index(after: close)
        guard open < text.endIndex, text[open] == "(",
              let end = text[open...].firstIndex(of: ")") else { return nil }
        let label = String(text[text.index(after: start)..<close])
        let target = String(text[text.index(after: open)..<end]).trimmingCharacters(in: .whitespaces)
        guard !label.contains("\n"), !target.isEmpty, !target.contains("\n") else { return nil }
        return (label, target, text.index(after: end))
    }

    private static func isLocalPath(_ target: String) -> Bool {
        target.hasPrefix("/") || target.hasPrefix("~/") || target.hasPrefix("file://")
    }

    /// `file://`, `~` и %-кодировка — в обычный путь; ссылки на сайты — как есть.
    private static func expand(_ target: String) -> String {
        if target.hasPrefix("file://"), let url = URL(string: target) { return url.path }
        if target.hasPrefix("~/") { return (target as NSString).expandingTildeInPath }
        if target.hasPrefix("/") { return target.removingPercentEncoding ?? target }
        return target
    }
}
