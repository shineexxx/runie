import Foundation

/// Разбор обновлений Bot API и то, что Руни показывает человеку.
///
/// Всё здесь — чистые превращения: обновление в запись, записи в текст. Живой
/// Телеграм для проверки не нужен.
public enum TelegramUpdates {

    /// Что пришло, если это не текст.
    static let kinds: [(field: String, name: String)] = [
        ("photo", "фото"), ("video", "видео"), ("voice", "голосовое"),
        ("video_note", "кружок"), ("audio", "аудио"), ("document", "файл"),
        ("sticker", "стикер"), ("location", "геопозиция"), ("contact", "контакт"),
        ("poll", "опрос"), ("story", "история")
    ]

    static func kind(of message: JSONValue) -> String? {
        kinds.first { message[$0.field] != nil }.map { t("\($0.name)") }
    }

    /// Имя собеседника: «Аня», «Александр Петров» или @ник.
    public static func title(of chat: JSONValue) -> String {
        let parts = [chat["first_name"]?.stringValue, chat["last_name"]?.stringValue]
        let name = parts.compactMap { $0 }.joined(separator: " ")
        if !name.isEmpty { return name }
        return chat["title"]?.stringValue
            ?? chat["username"]?.stringValue
            ?? chat["id"]?.intValue.map(String.init)
            ?? ""
    }

    /// Применяет одно обновление к хранилищу. Возвращает номер обновления,
    /// чтобы опрос знал, с какого места продолжать.
    @discardableResult
    public static func apply(_ update: JSONValue, to store: TelegramStore) throws -> Int64? {
        let number = update["update_id"]?.intValue.map(Int64.init)

        if let connection = update["business_connection"] {
            let rights = connection["rights"] ?? .object([:])
            try store.save(connection: TelegramStore.Connection(
                id: connection["id"]?.stringValue ?? "",
                userID: Int64(connection["user"]?["id"]?.intValue ?? 0),
                name: title(of: connection["user"] ?? .object([:])),
                // В новых версиях право лежит в `rights`, в старых — прямо в связи.
                canReply: rights["can_reply"]?.boolValue ?? connection["can_reply"]?.boolValue ?? false,
                enabled: connection["is_enabled"]?.boolValue ?? true
            ))
            return number
        }

        for field in ["business_message", "edited_business_message"] {
            guard let message = update[field] else { continue }
            try save(message, in: store)
        }

        if let deleted = update["deleted_business_messages"] {
            let chatID = Int64(deleted["chat"]?["id"]?.intValue ?? 0)
            let ids = (deleted["message_ids"]?.arrayValue ?? []).compactMap { $0.intValue.map(Int64.init) }
            try store.delete(chatID: chatID, messageIDs: ids)
        }
        return number
    }

    private static func save(_ message: JSONValue, in store: TelegramStore) throws {
        guard let chatID = message["chat"]?["id"]?.intValue.map(Int64.init) else { return }
        let connectionID = message["business_connection_id"]?.stringValue
            ?? store.connection()?.id ?? ""
        try store.save(chat: TelegramStore.Chat(
            id: chatID,
            title: title(of: message["chat"] ?? .object([:])),
            username: message["chat"]?["username"]?.stringValue,
            connectionID: connectionID
        ))
        let sender = message["from"]?["id"]?.intValue.map(Int64.init)
        try store.save(message: TelegramStore.Message(
            chatID: chatID,
            messageID: Int64(message["message_id"]?.intValue ?? 0),
            date: message["date"]?.intValue.map { Date(timeIntervalSince1970: Double($0)) } ?? Date(),
            outgoing: sender != nil && sender == store.connection()?.userID,
            text: message["text"]?.stringValue ?? message["caption"]?.stringValue ?? "",
            kind: kind(of: message)
        ))
    }

    // MARK: Что видит человек

    /// Когда это было: сегодня — время, раньше — дата.
    public static func when(_ date: Date, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = .runie
        formatter.dateFormat = now.timeIntervalSince(date) < 86_400 ? "HH:mm" : "d MMMM, HH:mm"
        return formatter.string(from: date)
    }

    /// Сводка входящих: кто написал и о чём, одной строкой на чат.
    public static func inbox(_ waiting: [TelegramStore.Waiting], hours: Int, waitingOnly: Bool,
                             now: Date = Date()) -> String {
        guard !waiting.isEmpty else {
            return waitingOnly
                ? t("Все ответили — никто не ждёт ответа.")
                : t("За последние \(hours) ч сообщений не было.")
        }
        let lines = waiting.map { item -> String in
            var preview = item.last.preview.replacingOccurrences(of: "\n", with: " ")
            if preview.count > 120 { preview = String(preview.prefix(119)) + "…" }
            return "- \(item.chat.display) — \(item.count), \(when(item.last.date, now: now)): \(preview)"
        }
        let header = waitingOnly ? t("Ждут ответа (\(waiting.count)):") : t("Написали за \(hours) ч:")
        return ([header] + lines).joined(separator: "\n")
    }

    /// Переписка с одним человеком.
    public static func thread(_ messages: [TelegramStore.Message], chat: TelegramStore.Chat,
                              me: String, now: Date = Date()) -> String {
        guard !messages.isEmpty else { return t("В этом чате пока ничего не накопилось.") }
        let lines = messages.map { message in
            "[\(when(message.date, now: now))] \(message.outgoing ? me : chat.title): \(message.preview)"
        }
        return ([t("Переписка с \(chat.title):")] + lines).joined(separator: "\n")
    }

    /// Найденное в переписке.
    public static func found(_ hits: [(chat: TelegramStore.Chat, message: TelegramStore.Message)],
                             query: String, me: String, now: Date = Date()) -> String {
        guard !hits.isEmpty else { return t("По запросу «\(query)» в переписке ничего нет.") }
        let lines = hits.map { hit in
            "[\(when(hit.message.date, now: now))] \(hit.message.outgoing ? me : hit.chat.title): \(hit.message.preview)"
        }
        return ([t("Нашёл \(hits.count):")] + lines).joined(separator: "\n")
    }
}
