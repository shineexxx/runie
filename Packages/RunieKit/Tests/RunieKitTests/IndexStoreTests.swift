import Foundation
import Testing
@testable import RunieKit

@Suite("Указатель по Mac")
struct IndexStoreTests {

    private func makeStore() throws -> IndexStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("runie-index-\(UUID().uuidString)/index.sqlite")
        return try IndexStore(url: url)
    }

    private func item(
        _ source: IndexStore.Source = .files, _ id: String, _ title: String, _ body: String = "",
        date: Date = Date(), details: [String: String] = [:]
    ) -> IndexStore.Item {
        IndexStore.Item(source: source, externalID: id, title: title, body: body, date: date, details: details)
    }

    @Test("запись кладётся, читается и не двоится при повторе")
    func put() throws {
        let store = try makeStore()
        let first = try store.put(item(.mail, "msg-1", "Смета на ремонт", "Пришлю к пятнице", details: ["from": "Саша"]))
        #expect(try store.count() == 1)

        // Тот же внешний номер — та же запись, только обновлённая.
        let second = try store.put(item(.mail, "msg-1", "Смета на ремонт", "Пришлю к четвергу"))
        #expect(first == second)
        #expect(try store.count() == 1)

        let found = try store.searchByWords("смета")
        #expect(found.count == 1)
        #expect(found.first?.item.body == "Пришлю к четвергу")
        #expect(found.first?.item.source == .mail)
    }

    @Test("поиск по словам: окончания, несколько слов, источники")
    func words() throws {
        let store = try makeStore()
        try store.put(item(.files, "/tmp/budget.xlsx", "Бюджет проекта", "Таблица расходов на сентябрь"))
        try store.put(item(.mail, "msg-2", "Фото со съёмки", "Отправил Ане восемь снимков"))
        try store.put(item(.notes, "note-1", "Идеи", "Позвонить в типографию"))

        #expect(try store.searchByWords("бюджета").count == 1)
        #expect(try store.searchByWords("таблица расходов").first?.item.externalID == "/tmp/budget.xlsx")
        #expect(try store.searchByWords("съёмка").first?.item.source == .mail)
        // Диакритика не мешает: «съёмки» находится и без ё.
        #expect(try store.searchByWords("съемки").count == 1)
        #expect(try store.searchByWords("типография").first?.item.source == .notes)
        #expect(try store.searchByWords("бюджет", sources: [.mail]).isEmpty)
        #expect(try store.searchByWords("велосипед").isEmpty)
        #expect(try store.searchByWords("  ").isEmpty)
    }

    @Test("кавычки и звёздочки в запросе не ломают поиск")
    func injection() throws {
        let store = try makeStore()
        try store.put(item(.files, "/tmp/a.txt", "Отчёт"))
        #expect(throws: Never.self) { try store.searchByWords("\"отчёт\" OR *") }
        #expect(throws: Never.self) { try store.searchByWords("a\" AND b\"") }
        #expect(IndexStore.ftsQuery("отчёт за август") == "\"отчет\"* AND \"за\"* AND \"авгус\"*")
        #expect(IndexStore.stem("типография") == "типогра")
        #expect(IndexStore.stem("report") == "report")
        #expect(IndexStore.ftsQuery("\"*") == "")
    }

    @Test("удаление записи и целого источника")
    func remove() throws {
        let store = try makeStore()
        try store.put(item(.files, "/tmp/a.txt", "Первый"))
        try store.put(item(.files, "/tmp/b.txt", "Второй"))
        try store.put(item(.mail, "msg-3", "Письмо"))

        try store.remove(source: .files, externalID: "/tmp/a.txt")
        #expect(try store.count(source: .files) == 1)
        #expect(try store.searchByWords("первый").isEmpty)

        try store.removeAll(source: .files)
        #expect(try store.count(source: .files) == 0)
        #expect(try store.count() == 1)
        #expect(try store.searchByWords("второй").isEmpty)
        #expect(try store.searchByWords("письмо").count == 1)
    }

    @Test("когда источник обходили в последний раз")
    func scans() throws {
        let store = try makeStore()
        #expect(store.lastScan(of: .mail) == nil)
        let moment = Date(timeIntervalSince1970: 1_790_000_000)
        try store.markScanned(.mail, at: moment)
        #expect(store.lastScan(of: .mail).map { abs($0.timeIntervalSince(moment)) < 0.001 } == true)
        #expect(store.lastScan(of: .files) == nil)
        try store.removeAll(source: .mail)
        #expect(store.lastScan(of: .mail) == nil)
    }

    @Test("вектор кладётся и читается тем же")
    func vectors() throws {
        let store = try makeStore()
        let vector: [Float] = (0..<256).map { Float($0) / 256 }
        let id = try store.put(item(.files, "/tmp/v.txt", "С вектором"), vector: vector)
        let stored = try store.vectors()
        #expect(stored.count == 1)
        #expect(stored.first?.id == id)
        // fp16 округляет, но не настолько, чтобы это мешало близости.
        let back = try #require(stored.first?.vector)
        #expect(back.count == 256)
        #expect(zip(back, vector).allSatisfy { abs($0 - $1) < 0.001 })
        #expect(try store.items(ids: [id])[id]?.title == "С вектором")
    }
}

@Suite("Поиск по указателю")
struct IndexSearchTests {

    private static let model = try? MemoryModel()

    private func filled() throws -> IndexStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("runie-search-\(UUID().uuidString)/index.sqlite")
        let store = try IndexStore(url: url)
        let rows: [(IndexStore.Source, String, String, String)] = [
            (.mail, "msg-1", "Смета на ремонт кухни", "Саша прислал таблицу с ценами на плитку"),
            (.files, "/tmp/report.pdf", "Годовой отчёт", "Выручка, расходы и планы на следующий год"),
            (.notes, "note-1", "Идеи для отпуска", "Горы, море, поехать в сентябре"),
            (.files, "/tmp/photo.jpg", "Снимки со съёмки", "Фотографии для Ани, восемь штук")
        ]
        for (source, id, title, body) in rows {
            let item = IndexStore.Item(source: source, externalID: id, title: title, body: body, date: Date())
            try store.put(item, vector: Self.model?.embed(title + " " + body))
        }
        return store
    }

    @Test("слова и смысл вместе: находит и точное совпадение, и перефраз")
    func hybrid() throws {
        let store = try filled()
        let words = IndexSearch(store: store)
        #expect(try words.search("плитка").first?.item.externalID == "msg-1")
        #expect(try words.search("выручка").first?.item.externalID == "/tmp/report.pdf")

        let model = try #require(Self.model, "модель не скачана — тест пропущен")
        let both = IndexSearch(store: store, model: model)
        #expect(try both.search("плитка").first?.item.externalID == "msg-1")
        // Ни одного общего слова с записью — только по словам это не найти.
        #expect(try words.search("куда поехать летом").isEmpty)
        #expect(try both.search("куда поехать летом").first?.item.externalID == "note-1")
    }

    @Test("поиск по одному источнику")
    func filtered() throws {
        let store = try filled()
        let search = IndexSearch(store: store, model: Self.model)
        #expect(try search.search("отчёт", sources: [.notes]).isEmpty)
        #expect(try search.search("отчёт", sources: [.files]).first?.item.source == .files)
    }
}
