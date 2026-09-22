import Foundation
import Testing
@testable import RunieKit

@Suite("Долгая память")
struct MemoryStoreTests {

    private func makeStore() throws -> MemoryStore {
        let store = MemoryStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("runie-memory-\(UUID().uuidString)"))
        try store.prepare()
        return store
    }

    @Test("подготовка создаёт профиль, индекс и папки")
    func prepare() throws {
        let store = try makeStore()
        #expect(FileManager.default.fileExists(atPath: store.profileURL.path))
        #expect(FileManager.default.fileExists(atPath: store.factsURL.path))
        #expect(FileManager.default.fileExists(atPath: store.journalURL.path))
        let index = try String(contentsOf: store.indexURL, encoding: .utf8)
        #expect(index.contains("Пока пусто"))
    }

    @Test("факт пишется с шапкой, попадает в индекс, читается обратно и забывается")
    func saveAndForget() throws {
        let store = try makeStore()
        let saved = try store.save(.init(name: "", kind: .feedback,
                                         description: "Предпочитает короткие ответы",
                                         body: "Без вступлений и повторов вопроса.\n\n**Почему:** экономит время."))
        #expect(saved.name == "predpocitaet-korotkie-otvety")
        let file = try String(contentsOf: store.factsURL.appendingPathComponent("\(saved.name).md"), encoding: .utf8)
        #expect(file.hasPrefix("---\nname: predpocitaet-korotkie-otvety\n"))
        #expect(file.contains("kind: feedback"))

        let index = try String(contentsOf: store.indexURL, encoding: .utf8)
        #expect(index.contains("## " + MemoryStore.Kind.feedback.title))
        #expect(index.contains("- [Предпочитает короткие ответы](facts/predpocitaet-korotkie-otvety.md)"))

        let read = try #require(store.fact(named: saved.name))
        #expect(read.description == "Предпочитает короткие ответы")
        #expect(read.body == "Без вступлений и повторов вопроса.\n\n**Почему:** экономит время.")
        #expect(read.kind == .feedback)

        // Перезапись тем же именем сохраняет дату создания.
        var updated = read
        updated.body = "Совсем коротко."
        let second = try store.save(updated)
        #expect(MemoryStore.dayName(second.created) == MemoryStore.dayName(read.created))
        #expect(store.facts().count == 1)

        try store.forget(named: saved.name)
        #expect(store.facts().isEmpty)
        #expect(throws: MemoryStore.Failure.notFound(saved.name)) { try store.forget(named: saved.name) }
    }

    @Test("проверки: пустое, плохое имя, секреты")
    func validation() throws {
        let store = try makeStore()
        #expect(throws: MemoryStore.Failure.empty) { try store.save(.init(name: "x", kind: .user, description: " ", body: "y")) }
        #expect(throws: MemoryStore.Failure.badName("Плохое Имя")) {
            try store.save(.init(name: "Плохое Имя", kind: .user, description: "a", body: "b"))
        }
        #expect(throws: MemoryStore.Failure.secret("ключ API")) {
            try store.save(.init(name: "k", kind: .reference, description: "Ключ", body: "sk-abcdefghijklmnopqrstuvwxyz"))
        }
        #expect(MemoryStore.secretLeak(in: "пароль: hunter2") == "пароль")
        #expect(MemoryStore.secretLeak(in: "карта 4111 1111 1111 1111") == "номер карты")
        #expect(MemoryStore.secretLeak(in: "коммит 9069dc4 и телефон +7 999 123-45-67") == nil)
        #expect(MemoryStore.secretLeak(in: "Встреча с Аней в четверг в 15:00") == nil)
    }

    @Test("дневник дописывается по дням, в промпт попадают последние")
    func journal() throws {
        let store = try makeStore()
        let calendar = Calendar(identifier: .gregorian)
        let today = Date()
        let weekAgo = try #require(calendar.date(byAdding: .day, value: -7, to: today))
        try store.addJournal("Сжал фото и подготовил письмо Ане", at: weekAgo)
        try store.addJournal("Выпустили 0.2.0", at: today)
        try store.addJournal("Обсудили\nпамять", at: today)

        let todayFile = try String(contentsOf: store.journalURL.appendingPathComponent(MemoryStore.dayName(today) + ".md"), encoding: .utf8)
        #expect(todayFile.hasPrefix("# " + MemoryStore.dayName(today)))
        #expect(todayFile.contains("Выпустили 0.2.0"))
        #expect(todayFile.contains("Обсудили память"))

        let recent = store.journal(days: 3, until: today)
        #expect(recent.count == 1)
        #expect(recent.first?.day == MemoryStore.dayName(today))

        let prompt = store.promptSection(now: today)
        #expect(prompt.contains("Выпустили 0.2.0"))
        #expect(!prompt.contains("письмо Ане"))
    }

    @Test("промпт: профиль, индекс и папка")
    func prompt() throws {
        let store = try makeStore()
        try store.setProfile("# Арсений\nДелает Runie.")
        try store.save(.init(name: "", kind: .project, description: "Runie — публичный репозиторий под MIT", body: "С 20 сентября 2026."))
        let prompt = store.promptSection()
        #expect(prompt.contains(store.root.path))
        #expect(prompt.contains("Делает Runie."))
        #expect(prompt.contains("- [Runie — публичный репозиторий под MIT](facts/runie-publicnyj-repozitorij-pod-mit.md)"))
        #expect(prompt.contains("memory_recall"))
        #expect(throws: MemoryStore.Failure.secret("пароль")) { try store.setProfile("password: qwerty") }
    }

    @Test("поиск по словам с окончаниями и по телу")
    func search() throws {
        let store = try makeStore()
        try store.save(.init(name: "", kind: .feedback, description: "Скриншоты сначала показывать, потом заливать в git", body: "Правило от 21 сентября."))
        try store.save(.init(name: "", kind: .project, description: "Проект RUN365", body: "Заказчики — Александр и Валентин, отчёты в Telegram."))
        try store.save(.init(name: "", kind: .user, description: "Любит кофе по утрам", body: "И разбор дня в 9:00."))

        let facts = store.facts()
        #expect(MemorySearch.search("правило про скриншот", in: facts).first?.fact.name == "skrinsoty-snacala-pokazyvat-potom-zalivat-v")
        #expect(MemorySearch.search("кто заказчик run365", in: facts).first?.fact.description == "Проект RUN365")
        #expect(MemorySearch.search("утренний кофе", in: facts).first?.fact.description == "Любит кофе по утрам")
        #expect(MemorySearch.search("", in: facts).isEmpty)
        #expect(MemorySearch.search("велосипед", in: facts).isEmpty)
    }

    @Test("инструменты памяти — своя группа разрешений, не рискованная")
    func permissions() {
        #expect(PermissionClassifier.categories(toolName: "mcp__runie__memory_save", input: .object([:])) == [.memory])
        #expect(PermissionClassifier.categories(toolName: "mcp__runie__memory_recall", input: .object([:])) == [.memory])
        #expect(!PermissionCategory.memory.isRisky)
        #expect(PermissionPolicy().rule(for: .memory) == .allow)
        #expect(PermissionPolicy().rule(for: .editFiles) == .ask)
        #expect(PermissionPolicy(rules: [.memory: .ask]).rule(for: .memory) == .ask)
    }

    @Test("забыть всё оставляет чистую папку")
    func forgetEverything() throws {
        let store = try makeStore()
        try store.save(.init(name: "", kind: .user, description: "Факт", body: "Тело"))
        try store.addJournal("Запись")
        try store.forgetEverything()
        #expect(store.facts().isEmpty)
        #expect(store.journal(days: 1).isEmpty)
        #expect(FileManager.default.fileExists(atPath: store.profileURL.path))
    }
}
