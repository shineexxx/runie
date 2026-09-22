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
            return fileAction(t("Читает"), input: input, fallback: t("Читает файл"))
        case "Write":
            return fileAction(t("Создаёт"), input: input, fallback: t("Создаёт файл"))
        case "Edit", "MultiEdit":
            return fileAction(t("Правит"), input: input, fallback: t("Правит файл"))
        case "NotebookEdit":
            return fileAction(t("Правит"), input: input, key: "notebook_path", fallback: t("Правит блокнот"))

        case "Bash":
            let command = input["command"]?.stringValue
            let summary = input["description"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            return Description(
                title: summary ?? t("Выполняет команду"),
                detail: command.map(firstLine).map(clip)
            )

        case "WebFetch":
            let url = input["url"]?.stringValue
            let host = url.flatMap { URL(string: $0)?.host() }
            return Description(
                title: host.map { t("Открывает \($0)") } ?? t("Открывает страницу"),
                detail: url.map(clip)
            )

        case "WebSearch":
            return Description(
                title: t("Ищет в интернете"),
                detail: input["query"]?.stringValue.map(clip)
            )

        case "Task", "Agent":
            return Description(
                title: t("Поручает задачу помощнику"),
                detail: input["description"]?.stringValue.map(clip)
            )

        case "TodoWrite":
            return Description(title: t("Обновляет план"), detail: nil)

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
                   + (paths.count > 3 ? t(" и ещё \(paths.count - 3)") : ""))

        switch tool {
        case "find_files":
            let query = input["query"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            return Description(title: query.map { t("Ищет «\($0)»") } ?? t("Ищет файлы"), detail: nil)
        case "reveal_in_finder":
            return Description(title: t("Показывает в Finder"), detail: filesDetail)
        case "open_files":
            return Description(title: t("Открывает файлы"), detail: filesDetail)
        case "compress_images":
            return Description(title: t("Сжимает картинки (\(paths.count))"), detail: filesDetail)
        case "zip_files":
            return Description(title: t("Упаковывает в архив"), detail: filesDetail)
        case "share_files":
            let via = switch input["via"]?.stringValue {
            case "mail": t("Почту")
            case "messages": t("Сообщения")
            case "airdrop": "AirDrop"
            default: t("меню «Поделиться»")
            }
            return Description(title: t("Готовит отправку через \(via)"), detail: filesDetail)
        case "browser_tabs", "browser_page_text", "browser_open", "browser_switch_tab", "browser_click", "browser_fill", "browser_run_js":
            let browser = input["browser"]?.stringValue == "chrome" ? "Chrome" : "Safari"
            switch tool {
            case "browser_tabs": return Description(title: t("Смотрит вкладки \(browser)"), detail: nil)
            case "browser_page_text": return Description(title: t("Читает страницу в \(browser)"), detail: nil)
            case "browser_open":
                let url = input["url"]?.stringValue
                return Description(title: t("Открывает \(url.flatMap { URL(string: $0)?.host() } ?? ")страницуt(") в \(browser)"), detail: url.map(clip))
            case "browser_switch_tab": return Description(title: t("Переходит на вкладку в \(browser)"), detail: nil)
            case "browser_run_js":
                // Код показывается целиком: человек разрешает именно его.
                let code = input["code"]?.stringValue ?? ""
                let shown = code.count > 2000 ? String(code.prefix(1999)) + "…" : code
                return Description(title: t("Выполняет JavaScript на странице в \(browser)"), detail: shown)
            case "browser_click":
                let target = input["text"]?.stringValue ?? input["selector"]?.stringValue ?? ""
                return Description(title: t("Нажимает «\(target)» в \(browser)"), detail: nil)
            default:
                let field = input["field"]?.stringValue ?? input["selector"]?.stringValue ?? t("поле")
                return Description(title: t("Заполняет «\(field)» в \(browser)"), detail: input["value"]?.stringValue.map(clip))
            }
        case "add_service":
            let name = input["name"]?.stringValue ?? t("сервис")
            return Description(title: t("Подключает сервис «\(name)»"), detail: input["url"]?.stringValue ?? input["command"]?.stringValue)
        case "remove_service":
            return Description(title: t("Отключает сервис «\(input["name"]?.stringValue ?? "")»"), detail: nil)
        case "save_skill":
            return Description(title: t("Сохраняет навык «\(input["name"]?.stringValue ?? "")»"), detail: input["description"]?.stringValue.map(clip))
        case "remove_skill":
            return Description(title: t("Удаляет навык «\(input["name"]?.stringValue ?? "")»"), detail: nil)
        case "ask_user":
            return Description(title: t("Спрашивает вас"), detail: input["question"]?.stringValue)
        case "list_extensions":
            return Description(title: t("Смотрит подключённые сервисы и навыки"), detail: nil)
        case "search_my_stuff":
            return Description(title: t("Ищет у вас: «\(input["query"]?.stringValue ?? "")»"), detail: nil)
        case "memory_save":
            return Description(title: t("Запоминает: «\(input["description"]?.stringValue ?? "")»"), detail: input["body"]?.stringValue.map(clip))
        case "memory_forget":
            return Description(title: t("Забывает «\(input["name"]?.stringValue ?? "")»"), detail: nil)
        case "memory_recall":
            return Description(title: t("Вспоминает про «\(input["query"]?.stringValue ?? "")»"), detail: nil)
        case "memory_journal":
            return Description(title: t("Записывает в дневник"), detail: input["note"]?.stringValue.map(clip))
        case "memory_profile":
            return Description(title: t("Обновляет профиль в памяти"), detail: input["text"]?.stringValue.map(clip))
        case "calendar_events":
            let range = switch input["range"]?.stringValue {
            case "tomorrow": t("на завтра")
            case "week": t("на неделю")
            default: t("на сегодня")
            }
            return Description(title: t("Смотрит встречи \(range)"), detail: nil)
        case "reminders":
            return Description(title: t("Смотрит напоминания"), detail: input["list"]?.stringValue)
        case "create_event":
            return Description(title: t("Добавляет встречу «\(input["title"]?.stringValue ?? "")»"),
                               detail: input["start"]?.stringValue)
        case "create_reminder":
            return Description(title: t("Добавляет напоминание «\(input["title"]?.stringValue ?? "")»"),
                               detail: input["due"]?.stringValue)
        case "complete_reminder":
            return Description(title: t("Отмечает напоминание выполненным"), detail: input["title"]?.stringValue)
        case "find_contact":
            return Description(title: t("Ищет контакт «\(input["name"]?.stringValue ?? "")»"), detail: nil)
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
