import Foundation

/// Подсказка под полем ввода: короткая надпись на кнопке и полная просьба,
/// которая уходит агенту по нажатию.
public struct Suggestion: Codable, Sendable, Hashable, Identifiable {
    public let label: String
    public let prompt: String

    public var id: String { label }

    public init(label: String, prompt: String) {
        self.label = label
        self.prompt = prompt
    }

    /// Готовые подсказки, пока ИИ не придумал свои: надпись и просьба совпадают.
    public static func fixed(_ labels: [String]) -> [Suggestion] {
        labels.map { Suggestion(label: $0, prompt: $0) }
    }
}

/// Что известно о человеке прямо сейчас — из этого ИИ придумывает подсказки.
///
/// Только то, что Руни и так может узнать без лишних разрешений: время, приложение
/// впереди, имена свежих файлов, темы недавних разговоров. Содержимое файлов не
/// читается.
public struct SuggestionContext: Sendable, Equatable {

    public struct RecentFile: Sendable, Equatable {
        public let name: String
        /// «Загрузки», «Рабочий стол».
        public let folder: String
        public let modified: Date

        public init(name: String, folder: String, modified: Date) {
            self.name = name
            self.folder = folder
            self.modified = modified
        }
    }

    public var date: Date
    public var appName: String?
    public var recentFiles: [RecentFile]
    public var recentConversations: [String]
    /// Что уже предлагали — чтобы не повторяться.
    public var previousSuggestions: [String]

    public init(
        date: Date = Date(),
        appName: String? = nil,
        recentFiles: [RecentFile] = [],
        recentConversations: [String] = [],
        previousSuggestions: [String] = []
    ) {
        self.date = date
        self.appName = appName
        self.recentFiles = recentFiles
        self.recentConversations = recentConversations
        self.previousSuggestions = previousSuggestions
    }

    /// Максимум символов в надписи: в ряд под полем помещаются две кнопки.
    public static let labelLimit = 24

    public func prompt(calendar: Calendar = .current) -> String {
        var lines: [String] = []
        let hour = calendar.component(.hour, from: date)
        let partOfDay = switch hour {
        case 5..<12: "утро"
        case 12..<18: "день"
        case 18..<23: "вечер"
        default: "ночь"
        }
        let weekday = calendar.component(.weekday, from: date)
        let weekdays = ["воскресенье", "понедельник", "вторник", "среда", "четверг", "пятница", "суббота"]
        lines.append("Сейчас: \(partOfDay), \(weekdays[(weekday - 1) % 7]).")

        if let appName {
            lines.append("Человек сейчас в приложении «\(appName)».")
        }
        if !recentFiles.isEmpty {
            let files = recentFiles.prefix(8).map { file in
                "\(file.name) (\(file.folder), \(Self.age(of: file.modified, now: date)))"
            }
            lines.append("Свежие файлы: " + files.joined(separator: "; ") + ".")
        }
        if !recentConversations.isEmpty {
            lines.append("Недавно просил Руни: " + recentConversations.prefix(5).map { "«\($0)»" }.joined(separator: ", ") + ".")
        }
        if !previousSuggestions.isEmpty {
            lines.append("Не повторяй эти подсказки: " + previousSuggestions.map { "«\($0)»" }.joined(separator: ", ") + ".")
        }

        return """
        Руни — ИИ-помощник на Mac. Он умеет работать с файлами и папками, запускать команды, \
        искать в интернете, управлять приложениями через AppleScript, читать календарь и напоминания.

        \(lines.joined(separator: "\n"))

        Придумай 2 подсказки: что человеку было бы полезно попросить у Руни прямо сейчас, \
        с учётом данных выше. Конкретные и разные, без общих слов.
        Ответь только JSON-массивом из двух объектов, без пояснений:
        [{"label": "надпись на кнопке, до \(Self.labelLimit) символов, по-русски", \
        "prompt": "полная просьба к Руни от первого лица человека, по-русски"}]
        """
    }

    private static func age(of date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        switch minutes {
        case ..<60: return "только что"
        case ..<(24 * 60): return "сегодня"
        case ..<(48 * 60): return "вчера"
        default: return "на днях"
        }
    }
}

/// Разбор ответа модели. Модели любят оборачивать JSON в ```json … ``` и добавлять
/// пояснения — разбор это переживает, а негодные подсказки отбрасывает.
public enum SuggestionParser {

    public static func parse(_ text: String) -> [Suggestion] {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let raw = try? JSONDecoder().decode([Raw].self, from: data)
        else { return [] }

        var seen = Set<String>()
        return raw.compactMap { item in
            let label = item.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let prompt = item.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? label
            guard !label.isEmpty, label.count <= SuggestionContext.labelLimit + 4,
                  seen.insert(label.lowercased()).inserted
            else { return nil }
            return Suggestion(label: label, prompt: prompt.isEmpty ? label : prompt)
        }
    }

    private struct Raw: Decodable {
        let label: String?
        let prompt: String?
    }
}
