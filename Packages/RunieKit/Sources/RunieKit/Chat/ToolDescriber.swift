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
            if let runie = describeRunie(name, input: input) {
                return runie
            }
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

    /// Встроенные инструменты Runie — своими словами.
    private static func describeRunie(_ name: String, input: JSONValue) -> Description? {
        guard name.hasPrefix("mcp__runie__") else { return nil }
        let tool = String(name.dropFirst("mcp__runie__".count))
        let paths = input["paths"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let filesDetail = paths.isEmpty ? nil
            : clip(paths.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
                   + (paths.count > 3 ? " и ещё \(paths.count - 3)" : ""))

        switch tool {
        case "find_files":
            let query = input["query"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            return Description(title: query.map { "Ищет «\($0)»" } ?? "Ищет файлы", detail: nil)
        case "reveal_in_finder":
            return Description(title: "Показывает в Finder", detail: filesDetail)
        case "open_files":
            return Description(title: "Открывает файлы", detail: filesDetail)
        case "compress_images":
            return Description(title: "Сжимает картинки (\(paths.count))", detail: filesDetail)
        case "zip_files":
            return Description(title: "Упаковывает в архив", detail: filesDetail)
        case "share_files":
            let via = switch input["via"]?.stringValue {
            case "mail": "Почту"
            case "messages": "Сообщения"
            case "airdrop": "AirDrop"
            default: "меню «Поделиться»"
            }
            return Description(title: "Готовит отправку через \(via)", detail: filesDetail)
        case "browser_tabs", "browser_page_text", "browser_open", "browser_switch_tab", "browser_click", "browser_fill", "browser_run_js":
            let browser = input["browser"]?.stringValue == "chrome" ? "Chrome" : "Safari"
            switch tool {
            case "browser_tabs": return Description(title: "Смотрит вкладки \(browser)", detail: nil)
            case "browser_page_text": return Description(title: "Читает страницу в \(browser)", detail: nil)
            case "browser_open":
                let url = input["url"]?.stringValue
                return Description(title: "Открывает \(url.flatMap { URL(string: $0)?.host() } ?? "страницу") в \(browser)", detail: url.map(clip))
            case "browser_switch_tab": return Description(title: "Переходит на вкладку в \(browser)", detail: nil)
            case "browser_run_js":
                // Код показывается целиком: человек разрешает именно его.
                let code = input["code"]?.stringValue ?? ""
                let shown = code.count > 2000 ? String(code.prefix(1999)) + "…" : code
                return Description(title: "Выполняет JavaScript на странице в \(browser)", detail: shown)
            case "browser_click":
                let target = input["text"]?.stringValue ?? input["selector"]?.stringValue ?? ""
                return Description(title: "Нажимает «\(target)» в \(browser)", detail: nil)
            default:
                let field = input["field"]?.stringValue ?? input["selector"]?.stringValue ?? "поле"
                return Description(title: "Заполняет «\(field)» в \(browser)", detail: input["value"]?.stringValue.map(clip))
            }
        case "calendar_events":
            let range = switch input["range"]?.stringValue {
            case "tomorrow": "на завтра"
            case "week": "на неделю"
            default: "на сегодня"
            }
            return Description(title: "Смотрит встречи \(range)", detail: nil)
        case "reminders":
            return Description(title: "Смотрит напоминания", detail: input["list"]?.stringValue)
        case "create_event":
            return Description(title: "Добавляет встречу «\(input["title"]?.stringValue ?? "")»",
                               detail: input["start"]?.stringValue)
        case "create_reminder":
            return Description(title: "Добавляет напоминание «\(input["title"]?.stringValue ?? "")»",
                               detail: input["due"]?.stringValue)
        case "complete_reminder":
            return Description(title: "Отмечает напоминание выполненным", detail: input["title"]?.stringValue)
        case "find_contact":
            return Description(title: "Ищет контакт «\(input["name"]?.stringValue ?? "")»", detail: nil)
        default:
            return nil
        }
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
