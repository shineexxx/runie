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

/// Приветствие в пустом чате и подсказки к нему — придумываются одним запросом.
public struct SuggestionSet: Codable, Sendable, Equatable {
    public let greeting: String?
    public let suggestions: [Suggestion]

    public init(greeting: String?, suggestions: [Suggestion]) {
        self.greeting = greeting
        self.suggestions = suggestions
    }

    /// Приветствие без ИИ — по времени суток.
    public static func fallbackGreeting(at date: Date = Date(), calendar: Calendar = .current) -> String {
        switch SuggestionContext.partOfDay(at: date, calendar: calendar) {
        case .morning: "Доброе утро! Чем помочь?"
        case .day: "Добрый день! Чем помочь?"
        case .evening: "Добрый вечер! Чем помочь?"
        case .night: "Не спится? Чем помочь?"
        }
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

    public enum PartOfDay: String, Sendable {
        case morning, day, evening, night

        var russian: String {
            switch self {
            case .morning: "утро"
            case .day: "день"
            case .evening: "вечер"
            case .night: "ночь"
            }
        }
    }

    public static func partOfDay(at date: Date, calendar: Calendar = .current) -> PartOfDay {
        switch calendar.component(.hour, from: date) {
        case 5..<12: .morning
        case 12..<18: .day
        case 18..<23: .evening
        default: .night
        }
    }

    /// Максимум символов в приветствии: оно помещается в одно облачко.
    public static let greetingLimit = 40

    public func prompt(calendar: Calendar = .current) -> String {
        var lines: [String] = []
        let hour = calendar.component(.hour, from: date)
        let partOfDay = Self.partOfDay(at: date, calendar: calendar).russian
        let weekday = calendar.component(.weekday, from: date)
        let weekdays = ["воскресенье", "понедельник", "вторник", "среда", "четверг", "пятница", "суббота"]
        lines.append("Сейчас: \(partOfDay), \(weekdays[(weekday - 1) % 7]), \(hour):00.")

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

        Придумай:
        1. Приветствие от Руни в пустом чате. Коротко, 2–6 слов, как скажет приятный \
        помощник: можно учесть время суток или приложение, и закончить простым вопросом. \
        Нельзя: советовать, намекать на задачи, упоминать файлы, папки и беспорядок, \
        оценивать человека или его привычки, шутить с подковыркой, риторические вопросы. \
        Примеры тона: «Добрый вечер! Чем займёмся?», «Привет! Чем помочь?», \
        «Доброе утро! С чего начнём?», «Поздно уже. Чем помочь?».
        2. Две подсказки: что человеку было бы полезно попросить у Руни прямо сейчас, \
        с учётом данных выше. Конкретные и разные, без общих слов. Надпись — нейтральное \
        действие («Пересказать PDF»), без оценок и нравоучений.
        Ответь только JSON, без пояснений:
        {"greeting": "приветствие", "suggestions": [{"label": "надпись на кнопке, до \(Self.labelLimit) символов", \
        "prompt": "полная просьба к Руни от первого лица человека"}]}
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

    /// Приветствие и подсказки. Годится и старый ответ — голый массив подсказок.
    public static func parseSet(_ text: String) -> SuggestionSet {
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
           let data = String(text[start...end]).data(using: .utf8),
           let object = try? JSONDecoder().decode(RawSet.self, from: data),
           object.suggestions != nil || object.greeting != nil {
            let greeting = object.greeting?.trimmingCharacters(in: .whitespacesAndNewlines)
            return SuggestionSet(
                greeting: greeting.flatMap { $0.isEmpty || $0.count > SuggestionContext.greetingLimit + 20 ? nil : $0 },
                suggestions: clean(object.suggestions ?? [])
            )
        }
        return SuggestionSet(greeting: nil, suggestions: parse(text))
    }

    public static func parse(_ text: String) -> [Suggestion] {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let raw = try? JSONDecoder().decode([Raw].self, from: data)
        else { return [] }
        return clean(raw)
    }

    private static func clean(_ raw: [Raw]) -> [Suggestion] {
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

    private struct RawSet: Decodable {
        let greeting: String?
        let suggestions: [Raw]?
    }

    private struct Raw: Decodable {
        let label: String?
        let prompt: String?
    }
}
