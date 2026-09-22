import Foundation
import RunieKit

// Долгая память Руни: факты, дневник и профиль в Markdown-файлах пользователя.
// Инструменты только пишут и читают папку памяти — ни сети, ни других файлов.

enum RunieMemory {
    nonisolated(unsafe) static var store = MemoryStore.standard
}

private let kindSchema: JSONValue = .object([
    "type": .string("string"),
    "enum": .array(MemoryStore.Kind.allCases.map { .string($0.rawValue) }),
    "description": .string("user — о человеке; feedback — как с ним работать; project — дела, договорённости, сроки; reference — ссылки")
])

struct MemorySaveTool: HostTool {
    let name = "memory_save"
    let description = """
    Запоминает факт надолго — в других разговорах он будет виден в индексе памяти. Одно дело — один факт. \
    description: одна строка, по которой факт узнаётся в индексе. body: сам факт с подробностями и почему это важно. \
    name — только чтобы обновить существующий факт из индекса; для нового не указывай. Пароли и ключи не сохраняются.
    """
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "description": .object(["type": .string("string"), "description": .string("Одна строка, суть")]),
            "body": .object(["type": .string("string"), "description": .string("Markdown: факт, почему важен, как применять")]),
            "kind": kindSchema,
            "name": .object(["type": .string("string"), "description": .string("Имя существующего факта из индекса (facts/<name>.md), чтобы обновить его")])
        ]),
        "required": .array([.string("description"), .string("body"), .string("kind")])
    ])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        let fact = MemoryStore.Fact(
            name: arguments["name"]?.stringValue ?? "",
            kind: arguments["kind"]?.stringValue.flatMap(MemoryStore.Kind.init(rawValue:)) ?? .user,
            description: arguments["description"]?.stringValue ?? "",
            body: arguments["body"]?.stringValue ?? ""
        )
        do {
            let saved = try RunieMemory.store.save(fact)
            return HostToolResult("Запомнил: «\(saved.description)» (facts/\(saved.fileName)). Появится в индексе со следующего разговора.")
        } catch {
            return HostToolResult(error.localizedDescription, isError: true)
        }
    }
}

struct MemoryForgetTool: HostTool {
    let name = "memory_forget"
    let description = "Забывает факт из памяти по имени файла из индекса (facts/<name>.md)."
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["name": .object(["type": .string("string")])]),
        "required": .array([.string("name")])
    ])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        let name = arguments["name"]?.stringValue ?? ""
        do {
            try RunieMemory.store.forget(named: name)
            return HostToolResult("Забыл «\(name)».")
        } catch {
            return HostToolResult(error.localizedDescription, isError: true)
        }
    }
}

struct MemoryRecallTool: HostTool {
    let name = "memory_recall"
    let description = """
    Достаёт подробности фактов из памяти: по имени из индекса или поиском по словам. \
    Возвращает полный текст найденных фактов. Пустой запрос — список всех фактов.
    """
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "query": .object(["type": .string("string"), "description": .string("Имя факта (facts/<name>.md) или слова для поиска")])
        ])
    ])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        let store = RunieMemory.store
        let query = (arguments["query"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let facts = store.facts()
        guard !facts.isEmpty else { return HostToolResult("В памяти пока нет фактов.") }
        if query.isEmpty {
            return HostToolResult(facts.map { "- \($0.name): \($0.description)" }.joined(separator: "\n"))
        }
        let name = query.replacingOccurrences(of: "facts/", with: "").replacingOccurrences(of: ".md", with: "")
        let found = store.fact(named: name).map { [$0] } ?? MemorySearch.search(query, in: facts).map(\.fact)
        guard !found.isEmpty else { return HostToolResult("По запросу «\(query)» в памяти ничего нет.") }
        let text = found.map { fact in
            "## \(fact.description)\n(facts/\(fact.fileName), \(fact.kind.rawValue), обновлено \(MemoryStore.dayName(fact.updated)))\n\(fact.body)"
        }
        return HostToolResult(text.joined(separator: "\n\n"))
    }
}

struct MemoryJournalTool: HostTool {
    let name = "memory_journal"
    let description = """
    Дописывает строку в дневник за сегодня: что сделали, что решили, что осталось. Коротко, одной фразой, \
    в прошедшем времени: «Сжал 8 фото и подготовил письмо Ане».
    """
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["note": .object(["type": .string("string")])]),
        "required": .array([.string("note")])
    ])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        do {
            try RunieMemory.store.addJournal(arguments["note"]?.stringValue ?? "")
            return HostToolResult("Записал в дневник.")
        } catch {
            return HostToolResult(error.localizedDescription, isError: true)
        }
    }
}

struct MemoryProfileTool: HostTool {
    let name = "memory_profile"
    let description = """
    Заменяет профиль человека в памяти целиком (Markdown). Текущий профиль ты видишь в разделе «Память» — \
    перепиши его с учётом нового, ничего не теряя. Коротко: имя, чем занимается, как любит работать.
    """
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["text": .object(["type": .string("string")])]),
        "required": .array([.string("text")])
    ])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        do {
            try RunieMemory.store.setProfile(arguments["text"]?.stringValue ?? "")
            return HostToolResult("Профиль обновлён.")
        } catch {
            return HostToolResult(error.localizedDescription, isError: true)
        }
    }
}
