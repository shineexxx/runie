import Foundation

/// Превращает вызов инструмента в строку, понятную не-программисту.
///
/// Лента «рук» из имён `Read`, `Bash`, `mcp__notion__search` ничего не говорит
/// человеку, для которого Runie сделан. «Читает todo.txt» — говорит.
public enum ToolDescriber {

    public struct Description: Sendable, Equatable {
        /// Короткая строка для ленты.
        public let title: String
        /// Подробность мелким шрифтом: путь, команда, адрес. Может отсутствовать.
        public let detail: String?
    }

    private static let detailLimit = 160

    public static func describe(name: String, input: JSONValue) -> Description {
        switch name {
        case "Read":
            return fileAction("Читает", input: input, fallback: "Читает файл")
        case "Write":
            return fileAction("Создаёт", input: input, fallback: "Создаёт файл")
        case "Edit", "MultiEdit":
            return fileAction("Правит", input: input, fallback: "Правит файл")
        case "NotebookEdit":
            return fileAction("Правит", input: input, key: "notebook_path", fallback: "Правит блокнот")

        case "Bash":
            let command = input["command"]?.stringValue
            let summary = input["description"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            return Description(
                title: summary ?? "Выполняет команду",
                detail: command.map(firstLine).map(clip)
            )

        case "WebFetch":
            let url = input["url"]?.stringValue
            let host = url.flatMap { URL(string: $0)?.host() }
            return Description(
                title: host.map { "Открывает \($0)" } ?? "Открывает страницу",
                detail: url.map(clip)
            )

        case "WebSearch":
            return Description(
                title: "Ищет в интернете",
                detail: input["query"]?.stringValue.map(clip)
            )

        case "Task", "Agent":
            return Description(
                title: "Поручает задачу помощнику",
                detail: input["description"]?.stringValue.map(clip)
            )

        case "TodoWrite":
            return Description(title: "Обновляет план", detail: nil)

        default:
            if let mcp = describeMCP(name) {
                return mcp
            }
            return Description(title: name, detail: nil)
        }
    }

    // MARK: - Частности

    private static func fileAction(
        _ verb: String,
        input: JSONValue,
        key: String = "file_path",
        fallback: String
    ) -> Description {
        guard let path = input[key]?.stringValue, !path.isEmpty else {
            return Description(title: fallback, detail: nil)
        }
        let name = (path as NSString).lastPathComponent
        return Description(title: "\(verb) \(name)", detail: clip(abbreviateHome(path)))
    }

    /// `mcp__server__tool_name` → «server: tool name».
    private static func describeMCP(_ name: String) -> Description? {
        let parts = name.components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp" else { return nil }
        let server = parts[1].replacingOccurrences(of: "_", with: " ")
        let tool = parts[2...].joined(separator: " ").replacingOccurrences(of: "_", with: " ")
        return Description(title: "\(server): \(tool)", detail: nil)
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first
        return line.map(String.init) ?? text
    }

    private static func clip(_ text: String) -> String {
        guard text.count > detailLimit else { return text }
        return String(text.prefix(detailLimit - 1)) + "…"
    }

    private static func abbreviateHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
