import Foundation
import SQLite3

/// Собирает переписку из Сообщений в указатель.
///
/// Читает базу `~/Library/Messages/chat.db` и только на чтение: чужую базу
/// Руни не трогает ни при каких обстоятельствах. Папка защищена, поэтому
/// нужен полный доступ к диску.
///
/// В указатель идут не отдельные сообщения, а разговор за день: «ок» и «еду»
/// поодиночке искать бесполезно, а «переписка с Аней 21 сентября» — уже вещь,
/// которую человек помнит и ищет.
public struct MessagesCollector: Sendable {

    /// Докуда дошли вглубь истории.
    static let depthMark = "messages.oldest"

    /// Сколько разговоров берём за проход.
    public var limit = 2_000
    public var maxTextLength = 20_000
    public var databaseURL: URL

    public init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Messages/chat.db")
    }

    /// Доступна ли база: заодно это проверка полного доступа к диску.
    public var canRead: Bool {
        FileManager.default.isReadableFile(atPath: databaseURL.path)
    }

    /// Одно сообщение из базы.
    struct Row {
        let date: Date
        let chat: String
        /// Кто написал: пусто — значит сам человек.
        let sender: String
        let text: String
        let fromMe: Bool
    }

    /// Разговор за один день: то, что кладём в указатель.
    struct Conversation {
        let chat: String
        let day: Date
        var lines: [String]
    }

    // MARK: Чтение базы

    /// Сообщения с текстом, новее `newerThan` или старее `olderThan`.
    ///
    /// Имя собеседника берём из названия группы, а если его нет — из адреса.
    /// Служебные записи без текста пропускаем сразу в запросе.
    static let query = """
        SELECT message.date, message.is_from_me, message.text, message.attributedBody,
               COALESCE(chat.display_name, ''), COALESCE(chat.chat_identifier, ''),
               COALESCE(handle.id, '')
        FROM message
        JOIN chat_message_join ON chat_message_join.message_id = message.ROWID
        JOIN chat ON chat.ROWID = chat_message_join.chat_id
        LEFT JOIN handle ON handle.ROWID = message.handle_id
        WHERE message.associated_message_type = 0
          AND (message.text IS NOT NULL OR message.attributedBody IS NOT NULL)
        ORDER BY message.date DESC
        """

    func rows(newerThan: Date?, olderThan: Date?, limit: Int) throws -> [Row] {
        var database: OpaquePointer?
        // Только чтение: чужую базу мы не трогаем ни при каких обстоятельствах.
        let flags = SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK, let database else {
            throw IndexStore.Failure.cannotOpen(databaseURL.lastPathComponent)
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, Self.query, -1, &statement, nil) == SQLITE_OK else {
            throw IndexStore.Failure.query(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        var result: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW, result.count < limit {
            let date = MessageText.date(fromAppleTime: sqlite3_column_int64(statement, 0))
            let isFresh = newerThan.map { date > $0 } ?? (olderThan == nil)
            let isHistory = olderThan.map { date < $0 } ?? false
            guard isFresh || isHistory else { continue }

            let fromMe = sqlite3_column_int(statement, 1) == 1
            let plain = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            var attributed: Data?
            if let blob = sqlite3_column_blob(statement, 3) {
                attributed = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 3)))
            }
            guard let text = MessageText.text(plain: plain, attributed: attributed) else { continue }

            let display = Self.text(statement, 4)
            let identifier = Self.text(statement, 5)
            let handle = Self.text(statement, 6)
            result.append(Row(
                date: date,
                chat: display.isEmpty ? identifier : display,
                sender: handle,
                text: text,
                fromMe: fromMe
            ))
        }
        return result
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    // MARK: Разговоры

    /// Складывает сообщения в разговоры по дням, новые дни первыми.
    static func conversations(from rows: [Row], calendar: Calendar = Calendar(identifier: .gregorian)) -> [Conversation] {
        var byKey: [String: Conversation] = [:]
        // Сообщения приходят от новых к старым — переворачиваем, чтобы в записи
        // разговор читался сверху вниз, как в самой переписке.
        for row in rows.reversed() {
            let day = calendar.startOfDay(for: row.date)
            let key = "\(row.chat)|\(day.timeIntervalSince1970)"
            let who = row.fromMe ? t("Я") : (row.sender.isEmpty ? row.chat : row.sender)
            byKey[key, default: Conversation(chat: row.chat, day: day, lines: [])]
                .lines.append("\(who): \(row.text)")
        }
        return byKey.values.sorted { $0.day > $1.day }
    }

    func item(from conversation: Conversation) -> IndexStore.Item {
        let day = conversation.day.formatted(.dateTime.day().month(.wide).year().locale(.runie))
        let body = conversation.lines.joined(separator: "\n")
        return IndexStore.Item(
            source: .messages,
            externalID: "chat:\(conversation.chat):\(MemoryStore.dayName(conversation.day))",
            title: t("Переписка с \(conversation.chat)") + ", " + day,
            body: String(body.prefix(maxTextLength)),
            date: conversation.day,
            details: ["chat": conversation.chat]
        )
    }

    /// Обходит переписку и складывает её в указатель по дням.
    @discardableResult
    public func scan(
        into store: IndexStore,
        model: MemoryModel? = nil,
        since: Date? = nil,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> Int {
        guard canRead else {
            throw IndexStore.Failure.cannotOpen(t("Сообщения — нужен полный доступ к диску"))
        }
        let start = Date()
        let since = since ?? store.lastScan(of: .messages)
        let depth = store.mark(Self.depthMark)

        var rows = try self.rows(newerThan: since, olderThan: nil, limit: limit)
        if rows.count < limit, let depth {
            rows += try self.rows(newerThan: nil, olderThan: depth, limit: limit - rows.count)
        }
        var oldest = depth
        for row in rows where oldest == nil || row.date < oldest! {
            oldest = row.date
        }

        var indexed = 0
        for conversation in Self.conversations(from: rows) {
            try Task.checkCancellation()
            let item = item(from: conversation)
            let vector = model?.embed(item.title + " " + String(item.body.prefix(1_000)))
            try store.put(item, vector: vector)
            indexed += 1
            if indexed % 25 == 0 {
                progress?(indexed)
                await Task.yield()
            }
        }
        if let oldest { try store.setMark(Self.depthMark, to: oldest) }
        try store.markScanned(.messages, at: start)
        progress?(indexed)
        return indexed
    }
}
