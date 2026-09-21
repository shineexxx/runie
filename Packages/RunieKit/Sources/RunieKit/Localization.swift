import Foundation

/// На каком языке Руни отвечает и придумывает подсказки. Интерфейс приложения идёт
/// за языком системы, а язык ответов человек выбирает сам: система у многих
/// английская, а разговаривать удобнее по-русски.
public enum AnswerLanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Как в системе: русский, если язык системы русский, иначе английский.
    case system
    case russian
    case english

    public var id: String { rawValue }

    /// `ru` или `en` — уже без «как в системе».
    public var code: String {
        switch self {
        case .russian: "ru"
        case .english: "en"
        case .system: Locale.current.language.languageCode?.identifier == "ru" ? "ru" : "en"
        }
    }

    public var isRussian: Bool { code == "ru" }

    /// Для дат и чисел в ответах инструментов.
    public var locale: Locale { isRussian ? Locale(identifier: "ru_RU") : Locale(identifier: "en_US") }

    /// Строка для системного промпта агента.
    public var promptLine: String {
        isRussian
            ? "Отвечай человеку по-русски."
            : "Always reply to the user in English, even if these instructions are written in another language."
    }

    /// Язык, выбранный в настройках Runie. Инструменты и форматирование дат живут
    /// вне интерфейса, и передавать выбор в каждый вызов было бы шумно.
    public static var current: AnswerLanguage {
        get {
            UserDefaults.standard.string(forKey: storageKey).flatMap(AnswerLanguage.init(rawValue:)) ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
        }
    }

    public static let storageKey = "answer.language"
}

extension Locale {
    /// Язык, на котором Руни разговаривает: им форматируются даты в ответах инструментов.
    public static var runie: Locale { AnswerLanguage.current.locale }
}

/// Строка интерфейса из RunieKit. Переводы лежат в самом пакете: приложение
/// показывает их как есть, а язык берётся из настроек системы.
func t(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}
