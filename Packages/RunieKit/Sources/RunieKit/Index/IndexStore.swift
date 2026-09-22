import Foundation
import SQLite3

/// Указатель по данным человека: файлы, письма, заметки — всё в одной базе.
///
/// Поиск идёт двумя способами сразу. По словам — полнотекстовым индексом SQLite,
/// он находит точные совпадения и терпит окончания. По смыслу — векторами той же
/// модели, что ищет по памяти: так находится письмо, где ни одного слова из
/// вопроса нет. Оба списка сливаются по рангу.
///
/// База лежит рядом с приложением и никуда не отправляется.
public final class IndexStore: @unchecked Sendable {

    /// Откуда запись. Каждый источник человек включает отдельно.
    public enum Source: String, CaseIterable, Codable, Sendable {
        case files
        case mail
        case notes
        case messages
        case photos

        public var title: String {
            switch self {
            case .files: t("Файлы")
            case .mail: t("Почта")
            case .notes: t("Заметки")
            case .messages: t("Сообщения")
            case .photos: t("Фото")
            }
        }
    }

    /// Запись указателя: одно письмо, один файл, одна заметка.
    public struct Item: Equatable, Sendable {
        public var source: Source
        /// Как найти это снова: путь к файлу, идентификатор письма.
        public var externalID: String
        public var title: String
        public var body: String
        /// Когда создано или изменено — по нему человек ищет «за прошлую неделю».
        public var date: Date
        /// Что ещё стоит знать: отправитель, папка, участники. Показывается в ответе.
        public var details: [String: String]

        public init(
            source: Source, externalID: String, title: String, body: String,
            date: Date, details: [String: String] = [:]
        ) {
            self.source = source
            self.externalID = externalID
            self.title = title
            self.body = body
            self.date = date
            self.details = details
        }
    }

    public struct Hit: Equatable, Sendable {
        public let item: Item
        public let score: Double
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case cannotOpen(String)
        case query(String)

        public var errorDescription: String? {
            switch self {
            case .cannotOpen(let reason): t("Не удалось открыть указатель: \(reason)")
            case .query(let reason): t("Ошибка в указателе: \(reason)")
            }
        }
    }

    /// `~/Library/Application Support/Runie/Index/index.sqlite`.
    public static var standardURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "Runie/Index/index.sqlite")
    }

    private var database: OpaquePointer?
    private let lock = NSLock()

    public init(url: URL = IndexStore.standardURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw Failure.cannotOpen(url.lastPathComponent)
        }
        database = handle
        // `runie_fold` — наша свёртка «ё» к «е»: её зовут триггеры индекса.
        sqlite3_create_function(handle, "runie_fold", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, _, values in
            guard let values, let raw = sqlite3_value_text(values[0]) else {
                sqlite3_result_null(context)
                return
            }
            let folded = String(cString: raw)
                .replacingOccurrences(of: "ё", with: "е")
                .replacingOccurrences(of: "Ё", with: "Е")
            sqlite3_result_text(context, folded, -1, IndexStore.copyText)
        }, nil, nil)
        try migrate()
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    // MARK: Схема

    private func migrate() throws {
        // WAL: сборщик пишет в фоне, поиск читает в это же время.
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("""
            CREATE TABLE IF NOT EXISTS items (
                id INTEGER PRIMARY KEY,
                source TEXT NOT NULL,
                external_id TEXT NOT NULL,
                title TEXT NOT NULL,
                body TEXT NOT NULL,
                date REAL NOT NULL,
                details TEXT NOT NULL DEFAULT '{}',
                updated REAL NOT NULL,
                UNIQUE (source, external_id)
            )
            """)
        // Полнотекстовый поиск: снимаем диакритику, чтобы «ёлка» и «елка» были одним.
        try execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
                title, body, content='items', content_rowid='id',
                tokenize="unicode61 remove_diacritics 2"
            )
            """)
        // Индекс слов живёт на триггерах: таблица внешняя, и трогать её руками
        // нельзя — SQLite считает такую базу испорченной. По дороге «ё» заменяется
        // на «е»: диакритику SQLite снимает сам, а вот эти две буквы считает
        // разными, и «съемка» не нашла бы «съёмку».
        try execute("""
            CREATE TRIGGER IF NOT EXISTS items_after_insert AFTER INSERT ON items BEGIN
                INSERT INTO items_fts (rowid, title, body)
                VALUES (new.id, runie_fold(new.title), runie_fold(new.body));
            END
            """)
        try execute("""
            CREATE TRIGGER IF NOT EXISTS items_after_delete AFTER DELETE ON items BEGIN
                INSERT INTO items_fts (items_fts, rowid, title, body)
                VALUES ('delete', old.id, runie_fold(old.title), runie_fold(old.body));
            END
            """)
        try execute("""
            CREATE TRIGGER IF NOT EXISTS items_after_update AFTER UPDATE ON items BEGIN
                INSERT INTO items_fts (items_fts, rowid, title, body)
                VALUES ('delete', old.id, runie_fold(old.title), runie_fold(old.body));
                INSERT INTO items_fts (rowid, title, body)
                VALUES (new.id, runie_fold(new.title), runie_fold(new.body));
            END
            """)
        try execute("CREATE INDEX IF NOT EXISTS items_date ON items (date)")
        try execute("CREATE INDEX IF NOT EXISTS items_source ON items (source)")
        // Векторы храним отдельно: они нужны только поиску по смыслу.
        try execute("""
            CREATE TABLE IF NOT EXISTS vectors (
                item_id INTEGER PRIMARY KEY REFERENCES items (id) ON DELETE CASCADE,
                vector BLOB NOT NULL
            )
            """)
        // Когда каждый источник обходили в последний раз.
        try execute("""
            CREATE TABLE IF NOT EXISTS sources (
                source TEXT PRIMARY KEY,
                scanned REAL NOT NULL
            )
            """)
    }

    // MARK: Запись

    /// Добавляет запись или обновляет её, если такая уже есть.
    /// `vector` — эмбеддинг заголовка с телом; без модели передаётся `nil`.
    @discardableResult
    public func put(_ item: Item, vector: [Float]? = nil) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let details = String(data: (try? JSONEncoder().encode(item.details)) ?? Data(), encoding: .utf8) ?? "{}"
        let statement = try prepare("""
            INSERT INTO items (source, external_id, title, body, date, details, updated)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (source, external_id) DO UPDATE SET
                title = excluded.title, body = excluded.body,
                date = excluded.date, details = excluded.details, updated = excluded.updated
            RETURNING id
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, item.source.rawValue)
        bind(statement, 2, item.externalID)
        bind(statement, 3, item.title)
        bind(statement, 4, item.body)
        sqlite3_bind_double(statement, 5, item.date.timeIntervalSince1970)
        bind(statement, 6, details)
        sqlite3_bind_double(statement, 7, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw Failure.query(lastError) }
        let id = sqlite3_column_int64(statement, 0)
        if let vector {
            try run("INSERT OR REPLACE INTO vectors (item_id, vector) VALUES (?, ?)") { statement in
                sqlite3_bind_int64(statement, 1, id)
                let data = Self.pack(vector)
                _ = data.withUnsafeBytes { raw in
                    sqlite3_bind_blob(statement, 2, raw.baseAddress, Int32(raw.count), Self.transient)
                }
            }
        }
        return id
    }

    /// Убирает запись — например, файл удалили.
    public func remove(source: Source, externalID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        for id in try identifiers(source: source, externalID: externalID) {
            try run("DELETE FROM vectors WHERE item_id = ?") { sqlite3_bind_int64($0, 1, id) }
            try run("DELETE FROM items WHERE id = ?") { sqlite3_bind_int64($0, 1, id) }
        }
    }

    /// Стирает всё из одного источника: человек выключил его в настройках.
    public func removeAll(source: Source) throws {
        lock.lock()
        defer { lock.unlock() }
        try run("DELETE FROM vectors WHERE item_id IN (SELECT id FROM items WHERE source = ?)") {
            self.bind($0, 1, source.rawValue)
        }
        try run("DELETE FROM items WHERE source = ?") { self.bind($0, 1, source.rawValue) }
        try run("DELETE FROM sources WHERE source = ?") { self.bind($0, 1, source.rawValue) }
    }

    public func count(source: Source? = nil) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let sql = source == nil ? "SELECT COUNT(*) FROM items" : "SELECT COUNT(*) FROM items WHERE source = ?"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        if let source { bind(statement, 1, source.rawValue) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Когда источник обходили в последний раз — чтобы не перебирать всё заново.
    public func lastScan(of source: Source) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        guard let statement = try? prepare("SELECT scanned FROM sources WHERE source = ?") else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, source.rawValue)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }

    public func markScanned(_ source: Source, at date: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        try run("INSERT OR REPLACE INTO sources (source, scanned) VALUES (?, ?)") { statement in
            self.bind(statement, 1, source.rawValue)
            sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
        }
    }

    // MARK: Поиск

    /// Ищет по словам. `query` — как человек написал, разбирается на слова сам.
    public func searchByWords(_ query: String, sources: Set<Source>? = nil, limit: Int = 20) throws -> [Hit] {
        let terms = Self.ftsQuery(query)
        guard !terms.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        // bm25 тем меньше, чем лучше совпадение; заголовок весит больше тела.
        let statement = try prepare("""
            SELECT items.id, items.source, items.external_id, items.title, items.body,
                   items.date, items.details, bm25(items_fts, 3.0, 1.0)
            FROM items_fts
            JOIN items ON items.id = items_fts.rowid
            WHERE items_fts MATCH ?
            ORDER BY bm25(items_fts, 3.0, 1.0)
            LIMIT ?
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, terms)
        sqlite3_bind_int(statement, 2, Int32(limit * 3))

        var hits: [Hit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let item = readItem(statement) else { continue }
            if let sources, !sources.contains(item.source) { continue }
            // Из bm25 делаем «чем больше, тем лучше», как у смысловой близости.
            let score = 1 / (1 + max(0, -sqlite3_column_double(statement, 7)))
            hits.append(Hit(item: item, score: score))
            if hits.count >= limit { break }
        }
        return hits
    }

    /// Все векторы с их записями — для поиска по смыслу.
    func vectors(sources: Set<Source>? = nil) throws -> [(id: Int64, vector: [Float])] {
        lock.lock()
        defer { lock.unlock() }
        let sql = """
            SELECT vectors.item_id, vectors.vector FROM vectors
            JOIN items ON items.id = vectors.item_id
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var result: [(Int64, [Float])] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            guard let bytes = sqlite3_column_blob(statement, 1) else { continue }
            let count = Int(sqlite3_column_bytes(statement, 1))
            let data = Data(bytes: bytes, count: count)
            result.append((id, Self.unpack(data)))
        }
        if let sources {
            let allowed = try identifiers(in: sources)
            return result.filter { allowed.contains($0.0) }
        }
        return result
    }

    func items(ids: [Int64]) throws -> [Int64: Item] {
        guard !ids.isEmpty else { return [:] }
        lock.lock()
        defer { lock.unlock() }
        let places = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let statement = try prepare("""
            SELECT id, source, external_id, title, body, date, details
            FROM items WHERE id IN (\(places))
            """)
        defer { sqlite3_finalize(statement) }
        for (index, id) in ids.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), id)
        }
        var result: [Int64: Item] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            if let item = readItem(statement) {
                result[sqlite3_column_int64(statement, 0)] = item
            }
        }
        return result
    }

    // MARK: Мелочи

    /// Номер записи в базе, если она есть.
    func identifier(source: Source, externalID: String) throws -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        return try identifiers(source: source, externalID: externalID).first
    }

    private func identifiers(source: Source, externalID: String) throws -> [Int64] {
        let statement = try prepare("SELECT id FROM items WHERE source = ? AND external_id = ?")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, source.rawValue)
        bind(statement, 2, externalID)
        var ids: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW { ids.append(sqlite3_column_int64(statement, 0)) }
        return ids
    }

    private func identifiers(in sources: Set<Source>) throws -> Set<Int64> {
        let places = Array(repeating: "?", count: sources.count).joined(separator: ",")
        let statement = try prepare("SELECT id FROM items WHERE source IN (\(places))")
        defer { sqlite3_finalize(statement) }
        for (index, source) in sources.enumerated() {
            bind(statement, Int32(index + 1), source.rawValue)
        }
        var ids: Set<Int64> = []
        while sqlite3_step(statement) == SQLITE_ROW { ids.insert(sqlite3_column_int64(statement, 0)) }
        return ids
    }

    private func readItem(_ statement: OpaquePointer?) -> Item? {
        guard let source = Source(rawValue: text(statement, 1)) else { return nil }
        let details = (try? JSONDecoder().decode([String: String].self, from: Data(text(statement, 6).utf8))) ?? [:]
        return Item(
            source: source,
            externalID: text(statement, 2),
            title: text(statement, 3),
            body: text(statement, 4),
            date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            details: details
        )
    }

    /// Запрос для FTS5: у слов отрезается окончание, и каждое ищется как начало
    /// слова. «Бюджета» так находит «бюджет», «типография» — «типографию».
    /// Кавычки и звёздочки человека внутрь не пускаем: он пишет вопрос, а не запрос.
    static func ftsQuery(_ query: String) -> String {
        let words = query
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map { stem(String($0)) }
            .filter { $0.count >= 2 }
        guard !words.isEmpty else { return "" }
        return words.map { "\"\($0)\"*" }.joined(separator: " AND ")
    }

    /// Основа слова: у длинных русских слов отрезается хвост, где живут окончания.
    /// Режем осторожнее, чем в памяти: там несколько коротких записей, а здесь
    /// десятки тысяч, и слишком короткая основа тянет за собой лишнее.
    static func stem(_ word: String) -> String {
        guard word.unicodeScalars.contains(where: { cyrillic.contains($0) }) else { return word }
        let word = word.replacingOccurrences(of: "ё", with: "е")
        guard word.count >= 6 else { return word }
        let keep = max(5, word.count - (word.count >= 9 ? 3 : 2))
        return String(word.prefix(keep))
    }

    private static let cyrillic = CharacterSet(charactersIn: "абвгдежзийклмнопрстуфхцчшщъыьэюяё")

    /// Вектор в fp16: 256 чисел занимают 512 байт вместо двух килобайт.
    static func pack(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * 2)
        for value in vector {
            var half = Float16(value)
            withUnsafeBytes(of: &half) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func unpack(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            let buffer = raw.bindMemory(to: Float16.self)
            return buffer.map { Float($0) }
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    /// SQLite должен скопировать строку себе: наша уйдёт сразу после вызова.
    static let copyText = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure.query(lastError)
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw Failure.query(lastError)
        }
    }

    private func run(_ sql: String, _ bind: (OpaquePointer?) -> Void) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(statement)
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw Failure.query(lastError) }
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    private var lastError: String {
        String(cString: sqlite3_errmsg(database))
    }
}
