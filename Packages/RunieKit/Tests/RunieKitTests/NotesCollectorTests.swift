import Foundation
import Testing
@testable import RunieKit

@Suite("Сбор заметок")
struct NotesCollectorTests {

    private let separator = AppleScriptRunner.fieldSeparator
    private let record = AppleScriptRunner.recordSeparator

    private func output(_ rows: [[String]]) -> String {
        rows.map { $0.joined(separator: separator) }.joined(separator: record)
    }

    @Test("ответ скрипта разбирается в записи")
    func parsing() {
        let text = output([
            ["x-coredata://ABC/ICNote/p1", "Идеи по Руни", "2026-09-22T17:55:09", "Телеграм-бот и указатель"],
            ["x-coredata://ABC/ICNote/p2", "Отпуск", "2026-09-20T09:00:00", "Горы, море, сентябрь"]
        ])
        let rows = NotesCollector.rows(from: text)
        #expect(rows.count == 2)
        #expect(rows.first?.title == "Идеи по Руни")
        #expect(rows.first?.body == "Телеграм-бот и указатель")
        #expect(rows.first.map { AppleScriptRunner.date(fromISO: "2026-09-22T17:55:09") == $0.date } == true)
        // Пустой ответ — ни одной записи, а не одна пустая.
        #expect(NotesCollector.rows(from: "").isEmpty)
        #expect(NotesCollector.rows(from: "\n  \n").isEmpty)
    }

    @Test("в теле остаются переводы строк и даже разделитель полей")
    func tricky() {
        let body = "Первая строка\nВторая\(separator)с разделителем"
        let rows = NotesCollector.rows(from: output([["id-1", "Заметка", "2026-09-22T10:00:00", body]]))
        #expect(rows.first?.body == body)
    }

    @Test("запись: заголовок не повторяется в теле, длина ограничена")
    func item() {
        let collector = NotesCollector()
        let row = NotesCollector.Row(
            id: "id-1", title: "Смета",
            date: Date(timeIntervalSince1970: 1_790_000_000),
            body: "Смета\nПлитка — 40 000"
        )
        let item = collector.item(from: row)
        #expect(item.source == .notes)
        #expect(item.title == "Смета")
        #expect(item.body == "Плитка — 40 000")
        #expect(item.externalID == "id-1")

        // Без заголовка берём начало текста: пустая строка в списке бесполезна.
        let untitled = collector.item(from: .init(id: "id-2", title: "", date: Date(), body: "Позвонить в типографию"))
        #expect(untitled.title == "Позвонить в типографию")
    }

    @Test("дата разбирается, мусор — нет")
    func dates() {
        #expect(AppleScriptRunner.date(fromISO: "2026-09-22T17:55:09") != nil)
        #expect(AppleScriptRunner.date(fromISO: "вторник, 22 сентября") == nil)
        #expect(AppleScriptRunner.date(fromISO: "") == nil)
    }
}
