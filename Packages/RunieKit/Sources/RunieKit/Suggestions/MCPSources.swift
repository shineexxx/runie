import Foundation

/// Сервер как источник данных для подсказок: включён ли и что с него брать.
public struct MCPSource: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// Что брать — обычными словами. Пусто — взять готовый запрос, если он есть.
    public var query: String

    public init(enabled: Bool = false, query: String = "") {
        self.enabled = enabled
        self.query = query
    }

    /// Запрос, который реально уйдёт: свой или готовый.
    public func effectiveQuery(forServer name: String) -> String? {
        let own = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? MCPSourcePresets.query(forServer: name) : own
    }
}

/// Готовые запросы для известных серверов.
public enum MCPSourcePresets {
    public static func query(forServer name: String) -> String? {
        let lower = name.lowercased()
        let presets: [(String, String)] = [
            ("slack", "Упоминания меня и личные сообщения за последние сутки: кто и о чём."),
            ("github", "Мои открытые pull request'ы и задачи, назначенные на меня: номер, название, репозиторий."),
            ("notion", "Страницы, изменённые за последние сутки: названия."),
            ("gmail", "Непрочитанные письма за последние сутки: от кого и тема."),
            ("linear", "Задачи, назначенные на меня, со сроком на этой неделе: название и срок."),
            ("jira", "Задачи, назначенные на меня, в работе: ключ и название."),
            ("drive", "Файлы, изменённые за последние сутки: названия.")
        ]
        return presets.first { lower.contains($0.0) }?.1
    }
}

/// Какие инструменты сервера можно вызывать при сборе данных для подсказок.
///
/// Сбор идёт без человека, поэтому пускаются только инструменты, которые по имени
/// читают (search, list, get…), и ни один, в имени которого есть действие —
/// отправить, создать, изменить, удалить. Лучше не прочитать лишнего, чем
/// отправить сообщение от имени человека.
public enum ReadOnlyTools {

    private static let readVerbs: Set<String> = [
        "search", "list", "get", "read", "fetch", "query", "find", "view", "retrieve",
        "lookup", "describe", "show", "count", "summarize", "history", "info", "status"
    ]

    private static let writeVerbs: Set<String> = [
        "send", "create", "update", "delete", "post", "write", "edit", "archive", "move",
        "add", "remove", "reply", "comment", "merge", "close", "set", "upload", "invite",
        "mark", "react", "schedule", "cancel", "draft", "modify", "patch", "put", "rename",
        "share", "star", "subscribe", "assign", "publish", "approve", "trash", "insert",
        "append", "replace", "duplicate", "fork", "push", "run", "execute", "trigger", "open"
    ]

    /// `mcp__claude_ai_Slack__slack_search_messages` для сервера «claude.ai Slack» → да.
    public static func allows(toolName: String, server: String) -> Bool {
        let prefix = MCPServerInfo.denyRule(forServer: server) + "__"
        guard toolName.hasPrefix(prefix) else { return false }
        let words = Set(toolName.dropFirst(prefix.count).lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return !words.isDisjoint(with: readVerbs) && words.isDisjoint(with: writeVerbs)
    }
}
