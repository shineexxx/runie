import Foundation

/// Одно событие из потока агента, ещё не приведённое к типам приложения.
///
/// На этом шаге намеренно не разбираем содержимое: задача рантайма — дотащить событие
/// целым. Превращение в типы приложения живёт отдельно (шаг 2), чтобы незнакомый
/// `type` никогда не ронял чтение потока.
public struct RawAgentEvent: Sendable, Equatable {
    /// Поле `type`. Пустая строка, если его не было.
    public let type: String
    /// Поле `subtype`, если есть.
    public let subtype: String?
    /// Поле `session_id`, если есть.
    public let sessionID: String?
    /// Событие целиком.
    public let payload: JSONValue

    public init(payload: JSONValue) {
        self.type = payload["type"]?.stringValue ?? ""
        self.subtype = payload["subtype"]?.stringValue
        self.sessionID = payload["session_id"]?.stringValue
        self.payload = payload
    }
}

/// Что рантайм отдаёт наружу.
public enum RuntimeOutput: Sendable, Equatable {
    /// Разобранное событие из stdout.
    case event(RawAgentEvent)
    /// Строка из stdout, которая не разобралась как JSON.
    ///
    /// Не ошибка выполнения: в stdout может попасть посторонний вывод. Показывать
    /// пользователю такое не надо, а в лог — надо.
    case malformedLine(String)
    /// Строка из stderr.
    case diagnostic(String)
    /// Процесс завершился. Поток после этого закрывается.
    case terminated(code: Int32, reason: TerminationReason)

    public enum TerminationReason: Sendable, Equatable {
        case exited
        case signalled
        /// Завершён по требованию приложения.
        case stopped
    }
}

/// Сообщение пользователя в формате, который ждёт `--input-format stream-json`.
public struct UserMessage: Sendable, Equatable {
    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    /// Одна строка NDJSON, готовая к записи в stdin, вместе с переводом строки.
    public func ndjsonLine() throws -> Data {
        var data = try JSONEncoder().encode(Payload(text: text))
        data.append(UInt8(ascii: "\n"))
        return data
    }

    private struct Payload: Encodable {
        let text: String

        enum CodingKeys: String, CodingKey { case type, message }
        enum MessageKeys: String, CodingKey { case role, content }
        enum BlockKeys: String, CodingKey { case type, text }

        func encode(to encoder: any Encoder) throws {
            var root = encoder.container(keyedBy: CodingKeys.self)
            try root.encode("user", forKey: .type)
            var message = root.nestedContainer(keyedBy: MessageKeys.self, forKey: .message)
            try message.encode("user", forKey: .role)
            var content = message.nestedUnkeyedContainer(forKey: .content)
            var block = content.nestedContainer(keyedBy: BlockKeys.self)
            try block.encode("text", forKey: .type)
            try block.encode(text, forKey: .text)
        }
    }
}
