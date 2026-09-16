import Foundation
import Testing
@testable import RunieKit

@Suite("AppContext")
struct AppContextTests {

    @Test("агенту уходит контекст, а сообщение остаётся в конце без изменений")
    func decoratesMessage() {
        let context = AppContext(bundleIdentifier: "com.apple.Safari", name: "Safari")
        let decorated = context.decorate("перескажи страницу")
        #expect(decorated.hasPrefix(context.agentPreamble))
        #expect(decorated.hasSuffix("\n\nперескажи страницу"))
        #expect(context.agentPreamble.contains("«Safari»"))
        #expect(context.agentPreamble.contains("com.apple.Safari"))
    }

    @Test("подсказки подбираются по семейству приложений")
    func suggestionsByFamily() {
        #expect(ContextSuggestions.suggestions(for: "com.apple.finder") == ["Разбери Загрузки", "Найди большие файлы"])
        #expect(ContextSuggestions.suggestions(for: "com.google.Chrome").first == "Перескажи страницу")
        #expect(ContextSuggestions.suggestions(for: "com.google.Chrome.canary").first == "Перескажи страницу")
        #expect(ContextSuggestions.suggestions(for: "com.jetbrains.intellij").first == "Объясни ошибку")
    }

    @Test("незнакомое приложение получает общие подсказки, а не пустой ряд")
    func unknownAppGetsFallback() {
        #expect(ContextSuggestions.suggestions(for: "com.example.unknown") == ContextSuggestions.fallback)
        #expect(!ContextSuggestions.fallback.isEmpty)
    }

    @Test("у каждого семейства ровно две подсказки: в ряд помещаются только две")
    func twoSuggestionsEach() {
        let ids = ["com.apple.finder", "com.apple.Safari", "com.apple.mail", "com.apple.iCal", "com.apple.Notes",
                   "com.apple.reminders", "com.apple.dt.Xcode", "ru.keepcoder.Telegram", "com.apple.Preview",
                   "com.apple.iWork.Pages", "com.apple.iWork.Numbers", "com.example.unknown"]
        for id in ids {
            #expect(ContextSuggestions.suggestions(for: id).count == 2, "\(id)")
        }
    }
}

@MainActor
@Suite("ChatSession с контекстом")
struct ChatSessionContextTests {

    @Test("в ленте текст пользователя, агенту — текст с контекстом")
    func contextGoesToAgentOnly() throws {
        let backend = FakeBackend()
        let session = ChatSession(backend: backend)
        let context = AppContext(bundleIdentifier: "com.apple.finder", name: "Finder")

        session.send("разбери загрузки", context: context)

        #expect(backend.connections.first?.sent == [context.decorate("разбери загрузки")])
        guard case .user(let item) = session.timeline.items.first else {
            Issue.record("первым должно быть сообщение пользователя")
            return
        }
        #expect(item.text == "разбери загрузки")
    }

    @Test("без контекста сообщение уходит как есть")
    func noContextSendsPlainText() {
        let backend = FakeBackend()
        let session = ChatSession(backend: backend)
        session.send("привет")
        #expect(backend.connections.first?.sent == ["привет"])
    }
}
