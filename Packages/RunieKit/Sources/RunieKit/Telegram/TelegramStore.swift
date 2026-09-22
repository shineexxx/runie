import Foundation
import SQLite3

/// Личная переписка, собранная из Телеграма: чаты, сообщения и состояние опроса.
///
/// Лежит в папке приложения, никуда не уходит и удаляется одной кнопкой вместе
/// с расширением. Поля `account` во всех таблицах — задел под облачную версию,
/// где аккаунтов будет несколько; пока он всегда один.
public final class TelegramStore: @unchecked Sendable {

    public struct Chat: Equatable, Sendable, Identifiable {
        public var id: Int64
        public var title: String
        public var username: String?
        public var connectionID: String

        public init(id: Int64, title: String, username: String? = nil, connectionID: String = "") {
            self.id = id
            self.title = title
            self.username = username
            self.connectionID = connectionID
        }

        /// Как называть человеку: «Аня (@anya)».
        public var display: String {
            username.map { "\(title) (@\($0))" } ?? title
        }
    }

    public struct Message: Equatable, Sendable {
        public var chatID: Int64
        public var messageID: Int64
        public var date: Date
        /// Написал сам человек (с телефона или через Руни).
        public var outgoing: Bool
        public var text: String
        /// Что пришло, если это не текст: «фото», «голосовое».
        public var kind: String?
        /// Человек уже ответил — чат больше не ждёт.
        public var answered: Bool

        public init(chatID: Int64, messageID: Int64, date: Date, outgoing: Bool,
                    text: String, kind: String? = nil, answered: Bool = false) {
            self.chatID = chatID
            self.messageID = messageID
            self.date = date
            self.outgoing = outgoing
            self.text = text
            self.kind = kind
            self.answered = answered
        }

        /// Текст или пометка о вложении: в сводке и переписке должно быть видно, что пришло.
        public var preview: String {
            if !text.isEmpty { return text }
            return kind.map { "[\($0)]" } ?? ""
        }
    }

    /// Чат в сводке входящих.
    public struct Waiting: Equatable, Sendable, Identifiable {
        public var chat: Chat
        public var count: Int
        public var last: Message
        public var id: Int64 { chat.id }
    }

    /// Бот, подключённый к аккаунту человека.
    public struct Connection: Equatable, Sendable {
        public var id: String
        public var userID: Int64
        public var name: String
        public var canReply: Bool
        public var enabled: Bool

        public init(id: String, userID: Int64, name: String, canReply: Bool, enabled: Bool) {
            self.id = id
            self.userID = userID
            self.name = name
            self.canReply = canReply
            self.enabled = enabled
        }
    }

    public enum Failure: Error, LocalizedError {
        case open(String)
        case query(String)

        public var errorDescription: String? {
            switch self {
            case .open(let reason): t("Не удалось открыть переписку: \(reason)")
            case .query(let reason): t("Ошибка в переписке: \(reason)")
            }
        }
    }

    /// `~/Library/Application Support/Runie/Telegram/messages.db`.
    public static var standardURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "Runie/Telegram/messages.db")
    }

    private var database: OpaquePointer?
    /// Рекурсивный: сводка достаёт последнее сообщение чата, не выходя из запроса.
    private let lock = NSRecursiveLock()
    private let account = "default"

    public init(url: URL = TelegramStore.standardURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw Failure.open(String(cString: sqlite3_errmsg(handle)))
        }
        database = handle
        try execute(Self.schema)
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    private static let schema = """
    CREATE TABLE IF NOT EXISTS chats (
        account TEXT NOT NULL, chat_id INTEGER NOT NULL, title TEXT NOT NULL DEFAULT '',
        username TEXT, connection_id TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (account, chat_id)
    );
    CREATE TABLE IF NOT EXISTS messages (
        account TEXT NOT NULL, chat_id INTEGER NOT NULL, message_id INTEGER NOT NULL,
        date REAL NOT NULL, outgoing INTEGER NOT NULL, text TEXT NOT NULL DEFAULT '',
        kind TEXT, answered INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (account, chat_id, message_id)
    );
    CREATE INDEX IF NOT EXISTS messages_by_date ON messages (account, date);
    CREATE TABLE IF NOT EXISTS state (
        account TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL,
        PRIMARY KEY (account, key)
    );
    """

    // MARK: Приём обновлений

    /// Запоминает бота, подключённого к аккаунту.
    public func save(connection: Connection) throws {
        try set("connection_id", connection.id)
        try set("my_id", String(connection.userID))
        try set("my_name", connection.name)
        try set("can_reply", connection.canReply ? "1" : "0")
        try set("enabled", connection.enabled ? "1" : "0")
    }

    public func connection() -> Connection? {
        guard let id = value("connection_id"), !id.isEmpty else { return nil }
        return Connection(
            id: id,
            userID: Int64(value("my_id") ?? "") ?? 0,
            name: value("my_name") ?? "",
            canReply: value("can_reply") == "1",
            enabled: value("enabled") != "0"
        )
    }

    public func save(chat: Chat) throws {
        try run("""
            INSERT INTO chats (account, chat_id, title, username, connection_id) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (account, chat_id) DO UPDATE SET title = excluded.title,
                username = excluded.username, connection_id = excluded.connection_id
            """) { statement in
            self.bind(statement, 1, self.account)
            sqlite3_bind_int64(statement, 2, chat.id)
            self.bind(statement, 3, chat.title)
            if let username = chat.username { self.bind(statement, 4, username) } else { sqlite3_bind_null(statement, 4) }
            self.bind(statement, 5, chat.connectionID)
        }
    }

    public func save(message: Message) throws {
        try run("""
            INSERT INTO messages (account, chat_id, message_id, date, outgoing, text, kind, answered)
            VALUES (?, ?, ?, ?, ?, ?, ?, 0)
            ON CONFLICT (account, chat_id, message_id) DO UPDATE SET
                date = excluded.date, text = excluded.text, kind = excluded.kind
            """) { statement in
            self.bind(statement, 1, self.account)
            sqlite3_bind_int64(statement, 2, message.chatID)
            sqlite3_bind_int64(statement, 3, message.messageID)
            sqlite3_bind_double(statement, 4, message.date.timeIntervalSince1970)
            sqlite3_bind_int(statement, 5, message.outgoing ? 1 : 0)
            self.bind(statement, 6, message.text)
            if let kind = message.kind { self.bind(statement, 7, kind) } else { sqlite3_bind_null(statement, 7) }
        }
        // Человек ответил сам — чат больше не ждёт ответа.
        if message.outgoing {
            try markAnswered(chatID: message.chatID)
        }
    }

    public func delete(chatID: Int64, messageIDs: [Int64]) throws {
        for messageID in messageIDs {
            try run("DELETE FROM messages WHERE account = ? AND chat_id = ? AND message_id = ?") { statement in
                self.bind(statement, 1, self.account)
                sqlite3_bind_int64(statement, 2, chatID)
                sqlite3_bind_int64(statement, 3, messageID)
            }
        }
    }

    public func markAnswered(chatID: Int64) throws {
        try run("UPDATE messages SET answered = 1 WHERE account = ? AND chat_id = ? AND outgoing = 0") { statement in
            self.bind(statement, 1, self.account)
            sqlite3_bind_int64(statement, 2, chatID)
        }
    }

    // MARK: Чтение

    /// Кто написал за последние часы. `waitingOnly` — только те, кому не ответили.
    public func waiting(hours: Int = 24, waitingOnly: Bool = true, now: Date = Date()) -> [Waiting] {
        let since = now.addingTimeInterval(-Double(hours) * 3600).timeIntervalSince1970
        var result: [Waiting] = []
        query("""
            SELECT m.chat_id, c.title, c.username, c.connection_id, COUNT(*) AS count,
                   SUM(CASE WHEN m.answered = 0 THEN 1 ELSE 0 END) AS waiting, MAX(m.date) AS last
            FROM messages m LEFT JOIN chats c ON c.chat_id = m.chat_id AND c.account = m.account
            WHERE m.account = ? AND m.outgoing = 0 AND m.date >= ?
            GROUP BY m.chat_id ORDER BY last DESC
            """, bind: { statement in
            self.bind(statement, 1, self.account)
            sqlite3_bind_double(statement, 2, since)
        }) { statement in
            let waitingCount = Int(sqlite3_column_int64(statement, 5))
            guard !waitingOnly || waitingCount > 0 else { return }
            let chatID = sqlite3_column_int64(statement, 0)
            let chat = Chat(
                id: chatID,
                title: self.text(statement, 1) ?? String(chatID),
                username: self.text(statement, 2),
                connectionID: self.text(statement, 3) ?? ""
            )
            guard let last = self.lastIncoming(chatID: chatID) else { return }
            result.append(Waiting(chat: chat, count: Int(sqlite3_column_int64(statement, 4)), last: last))
        }
        return result
    }

    private func lastIncoming(chatID: Int64) -> Message? {
        messages(chatID: chatID, limit: 1, incomingOnly: true).first
    }

    /// Переписка, от старых к новым.
    public func messages(chatID: Int64, limit: Int = 30, incomingOnly: Bool = false) -> [Message] {
        var result: [Message] = []
        let condition = incomingOnly ? "AND outgoing = 0" : ""
        query("""
            SELECT chat_id, message_id, date, outgoing, text, kind, answered FROM messages
            WHERE account = ? AND chat_id = ? \(condition) ORDER BY date DESC LIMIT ?
            """, bind: { statement in
            self.bind(statement, 1, self.account)
            sqlite3_bind_int64(statement, 2, chatID)
            sqlite3_bind_int(statement, 3, Int32(limit))
        }) { statement in
            result.append(self.message(from: statement))
        }
        return result.reversed()
    }

    /// Поиск по тексту переписки.
    public func search(_ needle: String, limit: Int = 20) -> [(chat: Chat, message: Message)] {
        let needle = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var result: [(Chat, Message)] = []
        query("""
            SELECT m.chat_id, m.message_id, m.date, m.outgoing, m.text, m.kind, m.answered,
                   c.title, c.username
            FROM messages m LEFT JOIN chats c ON c.chat_id = m.chat_id AND c.account = m.account
            WHERE m.account = ? AND m.text LIKE ? ORDER BY m.date DESC LIMIT ?
            """, bind: { statement in
            self.bind(statement, 1, self.account)
            self.bind(statement, 2, "%\(needle)%")
            sqlite3_bind_int(statement, 3, Int32(limit))
        }) { statement in
            let message = self.message(from: statement)
            let chat = Chat(
                id: message.chatID,
                title: self.text(statement, 7) ?? String(message.chatID),
                username: self.text(statement, 8)
            )
            result.append((chat, message))
        }
        return result
    }

    /// Все чаты, в которых что-то накопилось.
    public func chats() -> [Chat] {
        var result: [Chat] = []
        query("SELECT chat_id, title, username, connection_id FROM chats WHERE account = ? ORDER BY title",
              bind: { self.bind($0, 1, self.account) }) { statement in
            result.append(self.chat(from: statement))
        }
        return result
    }

    /// Чат по имени, `@нику` или номеру.
    ///
    /// Сравнение идёт в Swift, а не в SQL: `LIKE` в SQLite не различает регистр
    /// только у латиницы, и «алекс» не нашёл бы «Александра».
    public func findChat(_ needle: String) -> Chat? {
        let needle = needle.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !needle.isEmpty else { return nil }
        let all = chats()
        if let number = Int64(needle), let byNumber = all.first(where: { $0.id == number }) {
            return byNumber
        }
        let matches = all.filter { chat in
            chat.title.localizedCaseInsensitiveContains(needle)
                || (chat.username?.localizedCaseInsensitiveContains(needle) ?? false)
        }
        // Из нескольких подходящих — с самым коротким именем: оно ближе к запросу.
        return matches.min { $0.title.count < $1.title.count }
    }

    public func counts() -> (chats: Int, messages: Int) {
        (count("SELECT COUNT(*) FROM chats WHERE account = ?"),
         count("SELECT COUNT(*) FROM messages WHERE account = ?"))
    }

    // MARK: Состояние опроса

    public var offset: Int64? {
        get { value("offset").flatMap(Int64.init) }
        set { try? set("offset", newValue.map(String.init) ?? "") }
    }

    public var lastPoll: Date? {
        get { value("last_poll").flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) }
        set { try? set("last_poll", newValue.map { String($0.timeIntervalSince1970) } ?? "") }
    }

    public func value(_ key: String) -> String? {
        var result: String?
        query("SELECT value FROM state WHERE account = ? AND key = ?", bind: { statement in
            self.bind(statement, 1, self.account)
            self.bind(statement, 2, key)
        }) { statement in result = self.text(statement, 0) }
        return result
    }

    public func set(_ key: String, _ value: String) throws {
        try run("""
            INSERT INTO state (account, key, value) VALUES (?, ?, ?)
            ON CONFLICT (account, key) DO UPDATE SET value = excluded.value
            """) { statement in
            self.bind(statement, 1, self.account)
            self.bind(statement, 2, key)
            self.bind(statement, 3, value)
        }
    }

    // MARK: Мелочи SQLite

    private func message(from statement: OpaquePointer?) -> Message {
        Message(
            chatID: sqlite3_column_int64(statement, 0),
            messageID: sqlite3_column_int64(statement, 1),
            date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            outgoing: sqlite3_column_int(statement, 3) == 1,
            text: text(statement, 4) ?? "",
            kind: text(statement, 5),
            answered: sqlite3_column_int(statement, 6) == 1
        )
    }

    private func chat(from statement: OpaquePointer?) -> Chat {
        Chat(
            id: sqlite3_column_int64(statement, 0),
            title: text(statement, 1) ?? "",
            username: text(statement, 2),
            connectionID: text(statement, 3) ?? ""
        )
    }

    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, column) else { return nil }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw Failure.query(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func run(_ sql: String, bind: (OpaquePointer?) -> Void = { _ in }) throws {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure.query(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw Failure.query(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func query(_ sql: String, bind: (OpaquePointer?) -> Void, row: (OpaquePointer?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
    }

    private func count(_ sql: String) -> Int {
        var result = 0
        query(sql, bind: { self.bind($0, 1, self.account) }) { statement in
            result = Int(sqlite3_column_int64(statement, 0))
        }
        return result
    }
}
