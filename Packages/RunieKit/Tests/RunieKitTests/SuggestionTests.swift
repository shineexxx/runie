import Foundation
import Testing
@testable import RunieKit

@Suite("Подсказки от ИИ")
struct SuggestionTests {

    @Test("ответ в обёртке ```json разбирается")
    func parsesFenced() {
        let text = """
        Вот подсказки:
        ```json
        [{"label": "Пересказать PDF", "prompt": "Кратко перескажи свежие PDF из Загрузок"},
         {"label": "Разобрать Рабочий стол", "prompt": "Разложи файлы на Рабочем столе по папкам"}]
        ```
        """
        let suggestions = SuggestionParser.parse(text)
        #expect(suggestions.map(\.label) == ["Пересказать PDF", "Разобрать Рабочий стол"])
        #expect(suggestions[0].prompt == "Кратко перескажи свежие PDF из Загрузок")
    }

    @Test("приветствие и подсказки разбираются одним ответом")
    func parsesSet() {
        let text = """
        ```json
        {"greeting": "Добрый вечер! Разберём Загрузки?",
         "suggestions": [{"label": "Пересказать PDF", "prompt": "Перескажи свежие PDF"},
                         {"label": "Очистить Загрузки", "prompt": "Удали старые .dmg из Загрузок"}]}
        ```
        """
        let set = SuggestionParser.parseSet(text)
        #expect(set.greeting == "Добрый вечер! Разберём Загрузки?")
        #expect(set.suggestions.map(\.label) == ["Пересказать PDF", "Очистить Загрузки"])

        let legacy = SuggestionParser.parseSet(#"[{"label": "Раз", "prompt": "Раз"}]"#)
        #expect(legacy.greeting == nil)
        #expect(legacy.suggestions.count == 1)
    }

    @Test("приветствие без ИИ зависит от времени суток")
    func fallbackGreeting() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        func at(_ hour: Int) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: hour)))
        }
        #expect(SuggestionSet.fallbackGreeting(at: try at(8), calendar: calendar).hasPrefix("Доброе утро"))
        #expect(SuggestionSet.fallbackGreeting(at: try at(14), calendar: calendar).hasPrefix("Добрый день"))
        #expect(SuggestionSet.fallbackGreeting(at: try at(20), calendar: calendar).hasPrefix("Добрый вечер"))
        #expect(SuggestionSet.fallbackGreeting(at: try at(3), calendar: calendar).hasPrefix("Не спится"))
    }

    @Test("негодные подсказки отбрасываются")
    func dropsBad() {
        let text = """
        [{"label": ""}, {"label": "Очень длинная надпись, которая не поместится на кнопку"},
         {"label": "Повтор"}, {"label": "повтор"}, {"label": "Без просьбы"}]
        """
        let suggestions = SuggestionParser.parse(text)
        #expect(suggestions.map(\.label) == ["Повтор", "Без просьбы"])
        #expect(suggestions[1].prompt == "Без просьбы")
        #expect(SuggestionParser.parse("не JSON").isEmpty)
    }

    @Test("в запросе к модели — время, приложение, файлы, разговоры и что не повторять")
    func promptContainsContext() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Moscow"))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 20)))
        let context = SuggestionContext(
            date: date,
            appName: "Telegram",
            recentFiles: [.init(name: "отчёт.pdf", folder: "Загрузки", modified: date.addingTimeInterval(-600))],
            recentConversations: ["Сколько файлов в Загрузках?"],
            previousSuggestions: ["Календарь на сегодня"]
        )
        let prompt = context.prompt(calendar: calendar)
        #expect(prompt.contains("вечер, среда, 20:00"))
        #expect(prompt.contains("greeting"))
        #expect(prompt.contains("«Telegram»"))
        #expect(prompt.contains("отчёт.pdf (Загрузки, только что)"))
        #expect(prompt.contains("«Сколько файлов в Загрузках?»"))
        #expect(prompt.contains("Не повторяй эти подсказки: «Календарь на сегодня»"))
    }

    @Test("разовый запрос без инструментов, MCP, настроек и сохранения сессии")
    func lightweightArguments() {
        let generator = ClaudeSuggestionGenerator(executable: URL(fileURLWithPath: "/bin/claude"))
        let arguments = generator.arguments(for: SuggestionContext())
        #expect(arguments.contains("--print"))
        #expect(arguments.contains("--no-session-persistence"))
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(arguments[arguments.firstIndex(of: "--tools")! + 1] == "")
        #expect(arguments[arguments.firstIndex(of: "--model")! + 1] == "sonnet")
    }
}
