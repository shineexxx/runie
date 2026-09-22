import Foundation
import SQLite3
import Testing
@testable import RunieKit

@Suite("Сбор переписки")
struct MessagesCollectorTests {

    /// Делает базу, устроенную как настоящая `chat.db`.
    private func makeDatabase() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("runie-chat-\(UUID().uuidString)/chat.db")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        let schema = """
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, display_name TEXT, chat_identifier TEXT);
            CREATE TABLE message (
                ROWID INTEGER PRIMARY KEY, date INTEGER, is_from_me INTEGER,
                text TEXT, attributedBody BLOB, handle_id INTEGER,
                associated_message_type INTEGER DEFAULT 0
            );
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            """
        #expect(sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        return url
    }

    /// Время в базе Сообщений — наносекунды от 2001 года.
    private func appleTime(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSinceReferenceDate * 1_000_000_000)
    }

    private func fill(_ url: URL, _ sql: String) {
        var database: OpaquePointer?
        sqlite3_open(url.path, &database)
        sqlite3_exec(database, sql, nil, nil, nil)
        sqlite3_close(database)
    }

    @Test("текст берётся из обычного поля, а если его нет — из двоичного")
    func text() {
        #expect(MessageText.text(plain: "Привет", attributed: nil) == "Привет")
        #expect(MessageText.text(plain: "   ", attributed: nil) == nil)
        #expect(MessageText.text(plain: nil, attributed: nil) == nil)

        // Архив typedstream: после имени класса идёт длина и байты текста.
        let payload = Array("Еду, буду через час".utf8)
        var bytes: [UInt8] = Array("streamtyped".utf8) + [0x84, 0x84, 0x84]
        bytes += Array("NSString".utf8)
        bytes += [0x01, 0x94, 0x84, 0x01, 0x2B]
        bytes += [UInt8(payload.count)] + payload
        #expect(MessageText.text(plain: nil, attributed: Data(bytes)) == "Еду, буду через час")

        // Длинная строка: маркер 0x81 и два байта длины.
        let long = Array(String(repeating: "я", count: 200).utf8)
        var longBytes: [UInt8] = Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B, 0x81]
        longBytes += [UInt8(long.count & 0xFF), UInt8(long.count >> 8)] + long
        #expect(MessageText.text(plain: nil, attributed: Data(longBytes))?.count == 200)

        // Мусор не роняет разбор.
        #expect(MessageText.fromTypedStream(Data([0x01, 0x02, 0x03])) == nil)
        #expect(MessageText.fromTypedStream(Data("NSString".utf8)) == nil)
    }

    @Test("время: наносекунды и секунды от 2001 года")
    func dates() {
        let moment = Date(timeIntervalSinceReferenceDate: 800_000_000)
        #expect(abs(MessageText.date(fromAppleTime: 800_000_000_000_000_000).timeIntervalSince(moment)) < 1)
        // Старые записи хранили секунды.
        #expect(abs(MessageText.date(fromAppleTime: 800_000_000).timeIntervalSince(moment)) < 1)
    }

    @Test("сообщения складываются в разговор за день")
    func conversations() {
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        let rows = [
            // Приходят от новых к старым, как из базы.
            MessagesCollector.Row(date: day.addingTimeInterval(120), chat: "Аня", sender: "", text: "Еду", fromMe: true),
            MessagesCollector.Row(date: day.addingTimeInterval(60), chat: "Аня", sender: "+7999", text: "Ты где?", fromMe: false),
            MessagesCollector.Row(date: day.addingTimeInterval(-86_400), chat: "Аня", sender: "+7999", text: "Вчерашнее", fromMe: false),
            MessagesCollector.Row(date: day, chat: "Работа", sender: "+7111", text: "Созвон в 15", fromMe: false)
        ]
        let result = MessagesCollector.conversations(from: rows)
        // Три разговора: Аня сегодня, Аня вчера, Работа сегодня.
        #expect(result.count == 3)
        let anya = try? #require(result.first { $0.chat == "Аня" && $0.lines.count == 2 })
        // Порядок как в переписке: сначала вопрос, потом ответ.
        #expect(anya?.lines == ["+7999: Ты где?", t("Я") + ": Еду"])
    }

    @Test("разговор превращается в запись указателя")
    func item() {
        let collector = MessagesCollector()
        let conversation = MessagesCollector.Conversation(
            chat: "Аня",
            day: Date(timeIntervalSince1970: 1_790_000_000),
            lines: ["+7999: Ты где?", "Я: Еду"]
        )
        let item = collector.item(from: conversation)
        #expect(item.source == .messages)
        #expect(item.title.contains("Аня"))
        #expect(item.externalID.hasPrefix("chat:Аня:"))
        #expect(item.body.contains("Ты где?"))
        #expect(item.details["chat"] == "Аня")
    }

    @Test("обход читает настоящую базу и кладёт разговоры в указатель")
    func scan() async throws {
        let url = try makeDatabase()
        let now = Date()
        fill(url, """
            INSERT INTO handle (ROWID, id) VALUES (1, '+79990000000');
            INSERT INTO chat (ROWID, display_name, chat_identifier) VALUES (1, 'Аня', '+79990000000');
            INSERT INTO chat (ROWID, display_name, chat_identifier) VALUES (2, '', 'chat-работа');
            INSERT INTO message (ROWID, date, is_from_me, text, handle_id) VALUES
                (1, \(appleTime(now)), 0, 'Смета готова, скинул на почту', 1),
                (2, \(appleTime(now.addingTimeInterval(60))), 1, 'Спасибо, посмотрю', 1),
                (3, \(appleTime(now)), 0, 'Созвон перенесли на 15', 1);
            INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 1), (1, 2), (2, 3);
            """)

        let store = try IndexStore(url: url.deletingLastPathComponent().appending(path: "index.sqlite"))
        let collector = MessagesCollector(databaseURL: url)
        #expect(collector.canRead)
        let indexed = try await collector.scan(into: store)
        // Два разговора: с Аней и рабочий.
        #expect(indexed == 2)

        let found = try #require(try store.searchByWords("смета").first)
        #expect(found.item.source == .messages)
        #expect(found.item.body.contains("Смета готова"))
        #expect(found.item.body.contains(t("Я") + ": Спасибо"))
        // У чата без имени берётся его опознаватель.
        #expect(try store.searchByWords("созвон").first?.item.details["chat"] == "chat-работа")
        #expect(store.mark(MessagesCollector.depthMark) != nil)
    }

    @Test("без базы обход честно говорит, чего не хватает")
    func noAccess() async {
        let collector = MessagesCollector(databaseURL: URL(fileURLWithPath: "/нет/chat.db"))
        #expect(!collector.canRead)
        let store = try? IndexStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("runie-msg-\(UUID().uuidString)/index.sqlite"))
        await #expect(throws: IndexStore.Failure.self) { try await collector.scan(into: try #require(store)) }
    }
}
