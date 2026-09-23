import Foundation
import SQLite3

/// Собирает историю браузеров в указатель: что человек читал и когда.
///
/// «Где та статья про нотаризацию, которую я смотрел на прошлой неделе» — просьба
/// обычная, и отвечать на неё больше нечем: страницы у человека на диске не лежат.
///
/// Safari и Chrome ведут историю обычными базами SQLite, но каждый по-своему:
/// у Safari время считается от 2001 года, у Chrome — от 1601-го в микросекундах.
/// Обе базы открыты браузером, поэтому читаем не их, а свежую копию.
public struct HistoryCollector: Sendable {

    static let depthMark = "history.oldest"

    /// Сколько страниц берём за проход.
    public var limit = 5_000
    public var safariDatabase: URL
    public var chromeRoot: URL

    public init(safariDatabase: URL? = nil, chromeRoot: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.safariDatabase = safariDatabase ?? home.appending(path: "Library/Safari/History.db")
        self.chromeRoot = chromeRoot ?? ChromeCookies.standardRoot
    }

    /// Страница из истории. Одна и та же страница за разные дни — одна запись:
    /// человек ищет саму статью, а не каждый свой заход на неё.
    struct Page {
        let url: String
        let title: String
        let visited: Date
        let browser: String
    }

    // MARK: Что пропускаем

    /// Служебные адреса и локальная разработка: искать по ним нечего.
    static func isWorthIndexing(_ url: String) -> Bool {
        let lower = url.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return false }
        guard let host = URL(string: url)?.host()?.lowercased() else { return false }
        if host == "localhost" || host.hasPrefix("127.") || host.hasSuffix(".local") { return false }
        return true
    }

    /// Заголовок страницы, а если его нет — адрес без лишнего.
    static func title(for page: Page) -> String {
        let trimmed = page.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return trimmed }
        guard let url = URL(string: page.url), let host = url.host() else { return page.url }
        let path = url.path()
        return path.count > 1 ? host + path : host
    }

    func item(from page: Page) -> IndexStore.Item {
        let host = URL(string: page.url)?.host() ?? ""
        return IndexStore.Item(
            source: .history,
            externalID: "page:" + page.url,
            title: Self.title(for: page),
            // Адрес в теле: по нему тоже ищут — «та страница на habr».
            body: [host, page.url].filter { !$0.isEmpty }.joined(separator: "\n"),
            date: page.visited,
            details: ["browser": page.browser, "host": host]
        )
    }

    // MARK: Чтение баз

    /// Время Safari: секунды от 2001 года. Chrome: микросекунды от 1601-го.
    static func safariDate(_ value: Double) -> Date { Date(timeIntervalSinceReferenceDate: value) }

    static func chromeDate(_ value: Int64) -> Date {
        // Между 1601 и 1970 годами — 11 644 473 600 секунд.
        Date(timeIntervalSince1970: Double(value) / 1_000_000 - 11_644_473_600)
    }

    static let safariQuery = """
        SELECT history_items.url, COALESCE(history_visits.title, ''), MAX(history_visits.visit_time)
        FROM history_visits
        JOIN history_items ON history_items.id = history_visits.history_item
        GROUP BY history_items.url
        ORDER BY MAX(history_visits.visit_time) DESC
        """

    static let chromeQuery = """
        SELECT url, COALESCE(title, ''), last_visit_time
        FROM urls
        WHERE last_visit_time > 0
        ORDER BY last_visit_time DESC
        """

    /// Страницы из одной базы. Базу браузер держит открытой, поэтому работаем
    /// с копией: иначе SQLite отвечает «база занята».
    func pages(from database: URL, browser: String, newerThan: Date?, olderThan: Date?, limit: Int) -> [Page] {
        guard FileManager.default.isReadableFile(atPath: database.path) else { return [] }
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("runie-history-\(UUID().uuidString).db")
        // Вместе с базой копируем её журнал: последние страницы лежат ещё там,
        // и без него история выглядела бы обрезанной на несколько дней назад.
        let companions = ["-wal", "-shm"]
        defer {
            try? FileManager.default.removeItem(at: copy)
            for suffix in companions {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: copy.path + suffix))
            }
        }
        do {
            try FileManager.default.copyItem(at: database, to: copy)
            for suffix in companions {
                let source = URL(fileURLWithPath: database.path + suffix)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                try? FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: copy.path + suffix))
            }
        } catch {
            return []
        }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            return []
        }
        defer { sqlite3_close(handle) }

        let isSafari = browser == Self.safari
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, isSafari ? Self.safariQuery : Self.chromeQuery, -1, &statement, nil) == SQLITE_OK
        else { return [] }
        defer { sqlite3_finalize(statement) }

        var pages: [Page] = []
        while sqlite3_step(statement) == SQLITE_ROW, pages.count < limit {
            guard let rawURL = sqlite3_column_text(statement, 0) else { continue }
            let url = String(cString: rawURL)
            guard Self.isWorthIndexing(url) else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let visited = isSafari
                ? Self.safariDate(sqlite3_column_double(statement, 2))
                : Self.chromeDate(sqlite3_column_int64(statement, 2))
            let isFresh = newerThan.map { visited > $0 } ?? (olderThan == nil)
            let isHistory = olderThan.map { visited < $0 } ?? false
            guard isFresh || isHistory else { continue }
            pages.append(Page(url: url, title: title, visited: visited, browser: browser))
        }
        return pages
    }

    public static let safari = "Safari"
    public static let chrome = "Chrome"

    /// Базы всех браузеров: Safari и каждый профиль Chrome.
    func databases() -> [(url: URL, browser: String)] {
        var result: [(URL, String)] = [(safariDatabase, Self.safari)]
        let profiles = (try? FileManager.default.contentsOfDirectory(at: chromeRoot, includingPropertiesForKeys: nil)) ?? []
        for profile in profiles {
            let history = profile.appending(path: "History")
            if FileManager.default.fileExists(atPath: history.path) {
                result.append((history, Self.chrome))
            }
        }
        return result
    }

    /// Какие браузеры сейчас доступны для чтения. Если Safari нет в списке,
    /// значит его база закрыта — обычно не хватает полного доступа к диску.
    public func availableBrowsers() -> [String] {
        var names: [String] = []
        for (database, browser) in databases() where FileManager.default.isReadableFile(atPath: database.path) {
            if !names.contains(browser) { names.append(browser) }
        }
        return names
    }

    /// Обходит историю и складывает страницы в указатель.
    @discardableResult
    public func scan(
        into store: IndexStore,
        model: MemoryModel? = nil,
        since: Date? = nil,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> Int {
        let start = Date()
        let since = since ?? store.lastScan(of: .history)
        let depth = store.mark(Self.depthMark)

        var pages: [Page] = []
        for (database, browser) in databases() {
            pages += self.pages(from: database, browser: browser, newerThan: since, olderThan: nil, limit: limit)
            if pages.count < limit, let depth {
                pages += self.pages(from: database, browser: browser, newerThan: nil, olderThan: depth,
                                    limit: limit - pages.count)
            }
        }
        guard !pages.isEmpty else {
            try store.markScanned(.history, at: start)
            return 0
        }

        var oldest = depth
        var indexed = 0
        for page in pages {
            try Task.checkCancellation()
            let item = item(from: page)
            let vector = model?.embed(item.title + " " + String(item.body.prefix(200)))
            try store.put(item, vector: vector)
            indexed += 1
            if oldest == nil || page.visited < oldest! { oldest = page.visited }
            if indexed % 100 == 0 {
                progress?(indexed)
                await Task.yield()
            }
        }
        if let oldest { try store.setMark(Self.depthMark, to: oldest) }
        try store.markScanned(.history, at: start)
        progress?(indexed)
        return indexed
    }
}
