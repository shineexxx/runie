import Foundation

/// Разговор с Bot API Телеграма.
///
/// Обёрнуто протоколом, чтобы проверки шли без сети: подменяется целиком.
public protocol TelegramTransport: Sendable {
    func call(_ method: String, _ parameters: JSONValue, timeout: TimeInterval) async throws -> JSONValue
}

public struct TelegramAPI: TelegramTransport {

    public enum Failure: Error, Equatable, LocalizedError {
        case noToken
        case telegram(String)

        public var errorDescription: String? {
            switch self {
            case .noToken: t("Нет ключа бота — подключите Телеграм заново.")
            case .telegram(let reason): reason
            }
        }
    }

    /// Отдаёт ключ бота в момент вызова: человек мог ввести его только что.
    private let token: @Sendable () -> String?
    private let session: URLSession

    public init(token: @escaping @Sendable () -> String?, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    public func call(_ method: String, _ parameters: JSONValue, timeout: TimeInterval = 70) async throws -> JSONValue {
        guard let token = token(), !token.isEmpty else { throw Failure.noToken }
        var request = URLRequest(url: URL(string: "https://api.telegram.org/bot\(token)/\(method)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(parameters.jsonString().utf8)
        request.timeoutInterval = timeout
        let (data, _) = try await session.data(for: request)
        let body = try JSONValue.decode(data)
        guard body["ok"]?.boolValue == true else {
            throw Failure.telegram(body["description"]?.stringValue ?? t("Телеграм отказал без объяснений."))
        }
        return body["result"] ?? .object([:])
    }
}

public extension TelegramTransport {

    /// Долгий опрос: Телеграм держит соединение и отвечает, как только что-то пришло.
    func updates(after offset: Int64?, wait: Int = 50) async throws -> [JSONValue] {
        var parameters: [String: JSONValue] = [
            "timeout": .int(wait),
            "allowed_updates": .array([
                .string("business_connection"), .string("business_message"),
                .string("edited_business_message"), .string("deleted_business_messages")
            ])
        ]
        if let offset { parameters["offset"] = .int(Int(offset) + 1) }
        let result = try await call("getUpdates", .object(parameters), timeout: TimeInterval(wait) + 20)
        return result.arrayValue ?? []
    }

    /// Отправляет сообщение от имени человека.
    @discardableResult
    func send(connectionID: String, chatID: Int64, text: String) async throws -> JSONValue {
        try await call("sendMessage", .object([
            "business_connection_id": .string(connectionID),
            "chat_id": .int(Int(chatID)),
            "text": .string(text)
        ]), timeout: 30)
    }

    /// Проверяет ключ и возвращает имя бота.
    func botName() async throws -> String {
        let result = try await call("getMe", .object([:]), timeout: 20)
        return result["username"]?.stringValue ?? result["first_name"]?.stringValue ?? "бот"
    }
}
