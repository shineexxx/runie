import Foundation

/// Приложение, в котором человек работал, когда позвал Руни.
///
/// Пока это только название и идентификатор. Заголовок окна и адрес открытой
/// страницы требуют разрешений Accessibility и Automation — они появятся вместе
/// с брокером разрешений.
public struct AppContext: Sendable, Equatable {
    public let bundleIdentifier: String
    public let name: String

    public init(bundleIdentifier: String, name: String) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }

    /// Строка, которая уходит агенту перед сообщением пользователя. В ленте её нет:
    /// человек видит только то, что написал сам.
    public var agentPreamble: String {
        "[Контекст Runie: пользователь сейчас в приложении «\(name)» (\(bundleIdentifier)). "
            + "Учитывай это, только если просьба к нему относится.]"
    }

    /// Сообщение для агента с контекстом впереди.
    public func decorate(_ message: String) -> String {
        agentPreamble + "\n\n" + message
    }

    /// Подсказки под это приложение.
    public var suggestions: [String] {
        ContextSuggestions.suggestions(for: bundleIdentifier)
    }
}

/// Подсказки для пустого чата в зависимости от приложения впереди.
///
/// Короткие: в ряд помещаются две. Незнакомое приложение получает общие подсказки,
/// а не пустой ряд.
public enum ContextSuggestions {

    public static let fallback = ["Календарь на сегодня", "Вчерашние скриншоты"]

    private static let byFamily: [(prefixes: [String], suggestions: [String])] = [
        (["com.apple.finder"], ["Разбери Загрузки", "Найди большие файлы"]),
        (["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "org.mozilla.firefox", "com.microsoft.edgemac", "com.duckduckgo"],
         ["Перескажи страницу", "Сохрани в заметки"]),
        (["com.apple.mail", "com.readdle.smartemail", "com.google.Gmail"], ["Разбери входящие", "Черновик ответа"]),
        (["com.apple.iCal"], ["Что сегодня?", "Найди свободное окно"]),
        (["com.apple.Notes", "md.obsidian", "notion.id", "com.notion"], ["Наведи порядок в заметке", "Выдели задачи"]),
        (["com.apple.reminders"], ["Что просрочено?", "План на неделю"]),
        (["com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.jetbrains"],
         ["Объясни ошибку", "Что изменилось в проекте?"]),
        (["ru.keepcoder.Telegram", "org.telegram", "com.tinyspeck.slackmacgap", "com.apple.MobileSMS", "net.whatsapp"],
         ["Перескажи переписку", "Черновик ответа"]),
        (["com.apple.Preview", "com.adobe.Acrobat"], ["Перескажи документ", "Выпиши главное"]),
        (["com.apple.iWork.Pages", "com.microsoft.Word"], ["Проверь текст", "Сделай короче"]),
        (["com.apple.iWork.Numbers", "com.microsoft.Excel"], ["Объясни таблицу", "Найди ошибки в данных"])
    ]

    public static func suggestions(for bundleIdentifier: String) -> [String] {
        for family in byFamily where family.prefixes.contains(where: { bundleIdentifier.hasPrefix($0) }) {
            return family.suggestions
        }
        return fallback
    }
}
