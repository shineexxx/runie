import Foundation
import RunieKit

// Поиск по указателю: файлы, письма, заметки. Руни зовёт его, когда человек
// спрашивает про свои вещи, а не про общие знания.

struct SearchMyStuffTool: HostTool {
    let name = "search_my_stuff"
    let description = """
    Ищет по вещам человека: файлы, письма, заметки — по смыслу, а не по точному слову. \
    Зови, когда просят найти что-то своё («где та смета», «что там было про отпуск»), \
    в том числе когда человек не помнит ни имени файла, ни точной формулировки. \
    Возвращает подходящие записи с путями: файл потом можно открыть или показать в Finder. \
    Работает, только если человек включил указатель в настройках.
    """
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "query": .object([
                "type": .string("string"),
                "description": .string("Что ищем, словами человека: «смета на ремонт кухни»")
            ]),
            "sources": .object([
                "type": .string("array"),
                "description": .string("Где искать; без этого — везде"),
                "items": .object([
                    "type": .string("string"),
                    "enum": .array(IndexStore.Source.allCases.map { .string($0.rawValue) })
                ])
            ]),
            "limit": .object(["type": .string("integer"), "description": .string("Сколько записей вернуть, по умолчанию 8")])
        ]),
        "required": .array([.string("query")])
    ])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        let query = (arguments["query"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return HostToolResult("Нечего искать: пустой запрос.", isError: true) }
        let requested = (arguments["sources"]?.arrayValue ?? [])
            .compactMap { $0.stringValue.flatMap(IndexStore.Source.init(rawValue:)) }
        let sources = requested.isEmpty ? nil : Set(requested)
        let limit = min(max(arguments["limit"]?.intValue ?? 8, 1), 25)

        let enabled = await MainActor.run { IndexModel.shared.enabled }
        guard !enabled.isEmpty else {
            return HostToolResult(
                "Указатель выключен: человек не включал ни одного источника. Предложи открыть настройки, "
                + "раздел «Общие» → «Индекс», и скажи, что там же объясняется, зачем это нужно."
            )
        }

        do {
            let hits = try await IndexModel.shared.search(query, sources: sources, limit: limit)
            guard !hits.isEmpty else {
                return HostToolResult("По запросу «\(query)» в указателе ничего нет.")
            }
            return HostToolResult(hits.map(Self.describe).joined(separator: "\n\n"))
        } catch {
            return HostToolResult(error.localizedDescription, isError: true)
        }
    }

    /// Одна находка: чем является, как называется, где лежит и кусок текста.
    private static func describe(_ hit: IndexStore.Hit) -> String {
        var lines = ["## \(hit.item.title)"]
        var facts = [hit.item.source.title]
        facts.append(hit.item.date.formatted(.dateTime.day().month().year().locale(.runie)))
        if let sender = hit.item.details["from"] { facts.append("от: \(sender)") }
        if let kind = hit.item.details["kind"] { facts.append(kind) }
        lines.append(facts.joined(separator: ", "))
        if hit.item.source == .files {
            lines.append(hit.item.externalID)
        }
        let body = hit.item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            lines.append(body.count > 600 ? String(body.prefix(600)) + "…" : body)
        }
        return lines.joined(separator: "\n")
    }
}
