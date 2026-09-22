import Foundation
import Testing
@testable import RunieKit

/// Телеграм без Телеграма: обновления подсовываются такие же, какие присылает
/// Bot API, а сеть подменяется целиком.
@Suite("Телеграм")
struct TelegramTests {

    private func makeStore() throws -> TelegramStore {
        try TelegramStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("runie-tg-\(UUID().uuidString)/messages.db"))
    }

    private let now = Date()

    private func connection() -> JSONValue {
        .object(["business_connection": .object([
            "id": .string("conn-1"),
            "user": .object(["id": .int(777), "first_name": .string("Арсений")]),
            "date": .int(Int(now.timeIntervalSince1970)),
            "is_enabled": .bool(true),
            "rights": .object(["can_reply": .bool(true)])
        ]), "update_id": .int(1)])
    }

    private func incoming(_ chatID: Int, _ name: String, _ text: String,
                          secondsAgo: Int = 60, username: String? = nil,
                          from: Int? = nil, messageID: Int? = nil, update: Int = 2) -> JSONValue {
        var chat: [String: JSONValue] = ["id": .int(chatID), "first_name": .string(name), "type": .string("private")]
        if let username { chat["username"] = .string(username) }
        return .object([
            "update_id": .int(update),
            "business_message": .object([
                "business_connection_id": .string("conn-1"),
                "message_id": .int(messageID ?? chatID * 100 + secondsAgo),
                "date": .int(Int(now.timeIntervalSince1970) - secondsAgo),
                "chat": .object(chat),
                "from": .object(["id": .int(from ?? chatID), "first_name": .string(name)]),
                "text": .string(text)
            ])
        ])
    }

    private func seeded() throws -> TelegramStore {
        let store = try makeStore()
        try TelegramUpdates.apply(connection(), to: store)
        try TelegramUpdates.apply(incoming(1001, "Александр", "Когда будет отчёт по RUN365?", secondsAgo: 3600), to: store)
        try TelegramUpdates.apply(incoming(1001, "Александр", "И ещё: созвон в четверг?", secondsAgo: 1800), to: store)
        try TelegramUpdates.apply(incoming(1002, "Аня", "Скинь фото со съёмки", secondsAgo: 600, username: "anya"), to: store)
        try TelegramUpdates.apply(incoming(1003, "Валентин", "Спасибо, получил", secondsAgo: 300), to: store)
        // Человек ответил сам с телефона: сообщение от него же.
        try TelegramUpdates.apply(incoming(1003, "Валентин", "Пожалуйста!", secondsAgo: 200, from: 777,
                                           messageID: 100_399), to: store)
        return store
    }

    @Test("подключение бота запоминается")
    func connectionSaved() throws {
        let store = try makeStore()
        let number = try TelegramUpdates.apply(connection(), to: store)
        #expect(number == 1)
        let saved = try #require(store.connection())
        #expect(saved.id == "conn-1")
        #expect(saved.userID == 777)
        #expect(saved.name == "Арсений")
        #expect(saved.canReply)
        #expect(saved.enabled)
    }

    @Test("сообщения и чаты ложатся в базу, своё отличается от чужого")
    func messagesStored() throws {
        let store = try seeded()
        #expect(store.counts() == (chats: 3, messages: 5))
        let mine = store.messages(chatID: 1003).filter(\.outgoing)
        #expect(mine.count == 1)
        #expect(mine.first?.text == "Пожалуйста!")
    }

    @Test("сводка: только те, кто ждёт ответа")
    func inbox() throws {
        let store = try seeded()
        let waiting = store.waiting(now: now)
        #expect(waiting.map(\.chat.title) == ["Аня", "Александр"])
        // Валентину ответили — он ушёл из списка.
        #expect(!waiting.contains { $0.chat.title == "Валентин" })
        let text = TelegramUpdates.inbox(waiting, hours: 24, waitingOnly: true, now: now)
        #expect(text.contains("Ждут ответа (2)"))
        #expect(text.contains("Аня (@anya)"))
        #expect(text.contains("Скинь фото со съёмки"))
        // Без фильтра виден и отвеченный чат.
        #expect(store.waiting(waitingOnly: false, now: now).count == 3)
    }

    @Test("пустая сводка объясняет себя")
    func emptyInbox() throws {
        let store = try makeStore()
        #expect(TelegramUpdates.inbox([], hours: 24, waitingOnly: true).contains("Все ответили"))
        #expect(TelegramUpdates.inbox([], hours: 6, waitingOnly: false).contains("6 ч"))
        #expect(store.waiting().isEmpty)
    }

    @Test("переписка: от старых к новым, с именами")
    func thread() throws {
        let store = try seeded()
        let chat = try #require(store.findChat("Александр"))
        let messages = store.messages(chatID: chat.id)
        let text = TelegramUpdates.thread(messages, chat: chat, me: "Арсений", now: now)
        let first = try #require(text.range(of: "отчёт"))
        let second = try #require(text.range(of: "созвон"))
        #expect(first.lowerBound < second.lowerBound)
        #expect(text.contains("Александр: Когда будет отчёт"))
    }

    @Test("чат находится по имени, @нику и номеру")
    func findChat() throws {
        let store = try seeded()
        #expect(store.findChat("Александр")?.id == 1001)
        #expect(store.findChat("алекс")?.id == 1001)
        #expect(store.findChat("@anya")?.id == 1002)
        #expect(store.findChat("1003")?.id == 1003)
        #expect(store.findChat("Пётр") == nil)
        #expect(store.findChat("  ") == nil)
    }

    @Test("поиск по переписке")
    func search() throws {
        let store = try seeded()
        let hits = store.search("RUN365")
        #expect(hits.count == 1)
        #expect(hits.first?.chat.title == "Александр")
        let text = TelegramUpdates.found(hits, query: "RUN365", me: "Арсений", now: now)
        #expect(text.contains("Нашёл 1"))
        #expect(TelegramUpdates.found([], query: "квартира", me: "Я").contains("ничего нет"))
        #expect(store.search("  ").isEmpty)
    }

    @Test("ответ убирает чат из ждущих")
    func markAnswered() throws {
        let store = try seeded()
        try store.markAnswered(chatID: 1002)
        #expect(!store.waiting(now: now).contains { $0.chat.id == 1002 })
    }

    @Test("удалённое сообщение исчезает")
    func deleted() throws {
        let store = try seeded()
        let deleted = JSONValue.object([
            "update_id": .int(9),
            "deleted_business_messages": .object([
                "chat": .object(["id": .int(1002)]),
                "message_ids": .array([.int(1002 * 100 + 600)])
            ])
        ])
        try TelegramUpdates.apply(deleted, to: store)
        #expect(store.messages(chatID: 1002).isEmpty)
    }

    @Test("вложение без текста видно как пометка")
    func attachment() throws {
        let store = try makeStore()
        try TelegramUpdates.apply(connection(), to: store)
        let photo = JSONValue.object([
            "update_id": .int(5),
            "business_message": .object([
                "business_connection_id": .string("conn-1"),
                "message_id": .int(1),
                "date": .int(Int(now.timeIntervalSince1970)),
                "chat": .object(["id": .int(2001), "first_name": .string("Аня")]),
                "from": .object(["id": .int(2001)]),
                "photo": .array([.object(["file_id": .string("x")])])
            ])
        ])
        try TelegramUpdates.apply(photo, to: store)
        let message = try #require(store.messages(chatID: 2001).first)
        #expect(message.kind == "фото")
        #expect(message.preview == "[фото]")
    }

    @Test("номер обновления возвращается — опрос знает, где остановился")
    func offset() throws {
        let store = try makeStore()
        #expect(store.offset == nil)
        let number = try TelegramUpdates.apply(incoming(1001, "Аня", "привет", update: 42), to: store)
        #expect(number == 42)
        store.offset = number
        #expect(store.offset == 42)
    }

    @Test("отправка уходит от имени человека")
    func send() async throws {
        let transport = FakeTransport()
        try await transport.send(connectionID: "conn-1", chatID: 1001, text: "Отчёт будет завтра.")
        let call = await transport.calls.first
        #expect(call?.method == "sendMessage")
        #expect(call?.parameters["business_connection_id"]?.stringValue == "conn-1")
        #expect(call?.parameters["chat_id"]?.intValue == 1001)
        #expect(call?.parameters["text"]?.stringValue == "Отчёт будет завтра.")
    }

    @Test("долгий опрос просит только деловые обновления")
    func updates() async throws {
        let transport = FakeTransport()
        _ = try await transport.updates(after: 41)
        let call = try #require(await transport.calls.first)
        #expect(call.method == "getUpdates")
        // Следующее обновление — на единицу больше последнего разобранного.
        #expect(call.parameters["offset"]?.intValue == 42)
        let allowed = (call.parameters["allowed_updates"]?.arrayValue ?? []).compactMap(\.stringValue)
        #expect(allowed.contains("business_message"))
        #expect(allowed.contains("business_connection"))
    }

    @Test("отказ Телеграма объясняется словами")
    func failure() async {
        let api = TelegramAPI(token: { nil })
        await #expect(throws: TelegramAPI.Failure.noToken) { try await api.botName() }
        #expect(TelegramAPI.Failure.telegram("CHAT_WRITE_FORBIDDEN").errorDescription == "CHAT_WRITE_FORBIDDEN")
    }
}

/// Сеть на время проверок: запоминает вызовы и ничего никуда не отправляет.
private actor FakeTransport: TelegramTransport {
    struct Call: Sendable {
        let method: String
        let parameters: JSONValue
    }

    private(set) var calls: [Call] = []

    func call(_ method: String, _ parameters: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        calls.append(Call(method: method, parameters: parameters))
        return method == "getUpdates" ? .array([]) : .object(["message_id": .int(5555)])
    }
}
