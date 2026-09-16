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

/// Ответ на запрос разрешения в формате управляющего протокола stream-json.
///
/// Снято с CLI 2.1.272 при `--permission-prompt-tool stdio`: CLI присылает
/// `control_request` с подтипом `can_use_tool` и ждёт `control_response` в stdin.
/// Разрешение обязано вернуть входные данные инструмента в `updatedInput`.
public struct PermissionResponse: Sendable, Equatable {
    public let request: PermissionRequest
    public let decision: PermissionDecision

    public init(request: PermissionRequest, decision: PermissionDecision) {
        self.request = request
        self.decision = decision
    }

    public func ndjsonLine() throws -> Data {
        let answer: JSONValue = switch decision {
        case .allow:
            .object(["behavior": .string("allow"), "updatedInput": request.input])
        case .deny(let message):
            .object(["behavior": .string("deny"), "message": .string(message)])
        }
        let payload: JSONValue = .object([
            "type": .string("control_response"),
            "response": .object([
                "subtype": .string("success"),
                "request_id": .string(request.requestID),
                "response": answer
            ])
        ])
        var data = try JSONEncoder().encode(payload)
        data.append(UInt8(ascii: "\n"))
        return data
    }
}

/// Картинка, которая уходит агенту внутри сообщения — модель видит её сама.
public struct MessageImage: Sendable, Equatable {
    /// `image/png`, `image/jpeg`, `image/gif`, `image/webp`.
    public let mediaType: String
    public let data: Data

    public init(mediaType: String, data: Data) {
        self.mediaType = mediaType
        self.data = data
    }

    /// Типы, которые модель принимает как изображение.
    public static func mediaType(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        default: nil
        }
    }

    public static func load(from url: URL) throws -> MessageImage? {
        guard let type = mediaType(forExtension: url.pathExtension) else { return nil }
        return MessageImage(mediaType: type, data: try Data(contentsOf: url))
    }
}

/// Сообщение пользователя в формате, который ждёт `--input-format stream-json`.
///
/// Проверено на CLI 2.1.272: картинки идут блоками `image` с base64 перед текстом,
/// как в Messages API.
public struct UserMessage: Sendable, Equatable {
    public let text: String
    public let images: [MessageImage]

    public init(_ text: String, images: [MessageImage] = []) {
        self.text = text
        self.images = images
    }

    /// Одна строка NDJSON, готовая к записи в stdin, вместе с переводом строки.
    public func ndjsonLine() throws -> Data {
        var data = try JSONEncoder().encode(Payload(text: text, images: images))
        data.append(UInt8(ascii: "\n"))
        return data
    }

    private struct Payload: Encodable {
        let text: String
        let images: [MessageImage]

        enum CodingKeys: String, CodingKey { case type, message }
        enum MessageKeys: String, CodingKey { case role, content }
        enum BlockKeys: String, CodingKey { case type, text, source }
        enum SourceKeys: String, CodingKey { case type, media_type, data }

        func encode(to encoder: any Encoder) throws {
            var root = encoder.container(keyedBy: CodingKeys.self)
            try root.encode("user", forKey: .type)
            var message = root.nestedContainer(keyedBy: MessageKeys.self, forKey: .message)
            try message.encode("user", forKey: .role)
            var content = message.nestedUnkeyedContainer(forKey: .content)
            for image in images {
                var block = content.nestedContainer(keyedBy: BlockKeys.self)
                try block.encode("image", forKey: .type)
                var source = block.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
                try source.encode("base64", forKey: .type)
                try source.encode(image.mediaType, forKey: .media_type)
                try source.encode(image.data.base64EncodedString(), forKey: .data)
            }
            var block = content.nestedContainer(keyedBy: BlockKeys.self)
            try block.encode("text", forKey: .type)
            try block.encode(text, forKey: .text)
        }
    }
}
