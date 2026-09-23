import Foundation
import SQLite3
import Testing
@testable import RunieKit

@Suite("Сбор истории браузера")
struct HistoryCollectorTests {

    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("runie-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDatabase(at url: URL, schema: String, rows: String) {
        var handle: OpaquePointer?
        sqlite3_open(url.path, &handle)
        sqlite3_exec(handle, schema, nil, nil, nil)
        sqlite3_exec(handle, rows, nil, nil, nil)
        sqlite3_close(handle)
    }

    /// База Safari: время считается от 2001 года.
    private func makeSafari(at url: URL, visited: Date) {
        makeDatabase(
            at: url,
            schema: """
                CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT, visit_count INTEGER);
                CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL, title TEXT);
                """,
            rows: """
                INSERT INTO history_items (id, url) VALUES
                    (1, 'https://developer.apple.com/notarization'),
                    (2, 'http://localhost:3000/test'),
                    (3, 'https://example.com/без-заголовка');
                INSERT INTO history_visits (history_item, visit_time, title) VALUES
                    (1, \(visited.timeIntervalSinceReferenceDate), 'Нотаризация приложений'),
                    (1, \(visited.timeIntervalSinceReferenceDate - 86_400), 'Нотаризация приложений'),
                    (2, \(visited.timeIntervalSinceReferenceDate), 'Локальная разработка'),
                    (3, \(visited.timeIntervalSinceReferenceDate), '');
                """
        )
    }

    /// База Chrome: время в микросекундах от 1601 года.
    private func makeChrome(at url: URL, visited: Date) {
        let chromeTime = Int64((visited.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        makeDatabase(
            at: url,
            schema: "CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, last_visit_time INTEGER);",
            rows: """
                INSERT INTO urls (url, title, last_visit_time) VALUES
                    ('https://habr.com/ru/articles/12345', 'Как работает Spotlight', \(chromeTime)),
                    ('chrome://settings', 'Настройки', \(chromeTime));
                """
        )
    }

    @Test("время: у Safari от 2001 года, у Chrome от 1601-го")
    func dates() {
        let moment = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(abs(HistoryCollector.safariDate(moment.timeIntervalSinceReferenceDate).timeIntervalSince(moment)) < 1)
        let chrome = Int64((moment.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        #expect(abs(HistoryCollector.chromeDate(chrome).timeIntervalSince(moment)) < 1)
    }

    @Test("служебные и местные адреса мимо")
    func filtering() {
        #expect(HistoryCollector.isWorthIndexing("https://habr.com/ru/articles/1"))
        #expect(!HistoryCollector.isWorthIndexing("chrome://settings"))
        #expect(!HistoryCollector.isWorthIndexing("about:blank"))
        #expect(!HistoryCollector.isWorthIndexing("file:///Users/arseny/файл.html"))
        #expect(!HistoryCollector.isWorthIndexing("http://localhost:3000/test"))
        #expect(!HistoryCollector.isWorthIndexing("http://127.0.0.1:8080"))
        #expect(!HistoryCollector.isWorthIndexing("https://mac.local/страница"))
    }

    @Test("без заголовка берём адрес")
    func titles() {
        let now = Date()
        #expect(HistoryCollector.title(for: .init(url: "https://a.ru/x", title: "Статья", visited: now, browser: "Safari")) == "Статья")
        #expect(HistoryCollector.title(for: .init(url: "https://habr.com/ru/1", title: "  ", visited: now, browser: "Safari")) == "habr.com/ru/1")
        #expect(HistoryCollector.title(for: .init(url: "https://habr.com", title: "", visited: now, browser: "Safari")) == "habr.com")
    }

    @Test("страницы читаются из обеих баз, одна страница — одна запись")
    func scan() async throws {
        let folder = try makeFolder()
        let visited = Date().addingTimeInterval(-3_600)
        let safari = folder.appending(path: "History.db")
        makeSafari(at: safari, visited: visited)

        let chromeRoot = folder.appending(path: "Chrome")
        let profile = chromeRoot.appending(path: "Default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        makeChrome(at: profile.appending(path: "History"), visited: visited)

        let store = try IndexStore(url: folder.appending(path: "index.sqlite"))
        let collector = HistoryCollector(safariDatabase: safari, chromeRoot: chromeRoot)
        let indexed = try await collector.scan(into: store)

        // Три страницы: статья Apple, страница без заголовка и статья с Хабра.
        // Локальная разработка и chrome://settings отброшены.
        #expect(indexed == 3)
        let found = try #require(try store.searchByWords("нотаризация").first)
        #expect(found.item.title == "Нотаризация приложений")
        #expect(found.item.details["browser"] == "Safari")
        #expect(found.item.details["host"] == "developer.apple.com")

        let habr = try #require(try store.searchByWords("spotlight").first)
        #expect(habr.item.details["browser"] == "Chrome")
        // По адресу тоже находится: «та страница на habr».
        #expect(try store.searchByWords("habr").first?.item.details["host"] == "habr.com")
        #expect(store.mark(HistoryCollector.depthMark) != nil)

        // Второй обход не двоит записи.
        try await collector.scan(into: store, since: nil)
        #expect(try store.count(source: .history) == 3)
    }

    @Test("нет баз — нет и беды")
    func missing() async throws {
        let folder = try makeFolder()
        let store = try IndexStore(url: folder.appending(path: "index.sqlite"))
        let collector = HistoryCollector(
            safariDatabase: folder.appending(path: "нет.db"),
            chromeRoot: folder.appending(path: "нет")
        )
        #expect(try await collector.scan(into: store) == 0)
        #expect(store.lastScan(of: .history) != nil)
    }
}
