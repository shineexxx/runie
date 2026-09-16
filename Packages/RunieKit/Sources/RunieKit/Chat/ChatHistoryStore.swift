import Foundation

/// Сохранённый разговор с Руни.
public struct ConversationRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    /// Сессия Claude Code: по ней разговор продолжается с того же места.
    public var sessionID: String?
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date
    public var items: [TimelineItem]

    public init(id: UUID, sessionID: String?, title: String, createdAt: Date, updatedAt: Date, items: [TimelineItem]) {
        self.id = id
        self.sessionID = sessionID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.items = items
    }

    /// Заголовок из первого сообщения человека.
    public static func title(for items: [TimelineItem]) -> String {
        let first = items.lazy.compactMap { if case .user(let user) = $0 { user.text } else { nil } }.first
        let line = (first ?? "Разговор").split(whereSeparator: \.isNewline).first.map(String.init) ?? "Разговор"
        return line.count > 70 ? String(line.prefix(70)) + "…" : line
    }

    /// Последняя реплика Руни — для подписи в списке.
    public var preview: String? {
        items.reversed().lazy.compactMap { if case .assistant(let item) = $0 { item.text } else { nil } }.first
    }
}

/// История разговоров: по файлу JSON на разговор.
///
/// Хранится у себя, а не в журналах Claude Code: там же лежат сессии, которые человек
/// запускал в терминале, и формат журналов CLI не обещает не менять.
public struct ChatHistoryStore: Sendable {

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Папка по умолчанию: `~/Library/Application Support/Runie/Conversations`.
    public static func standard() -> ChatHistoryStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ChatHistoryStore(directory: base.appending(path: "Runie/Conversations", directoryHint: .isDirectory))
    }

    private func url(for id: UUID) -> URL {
        directory.appending(path: id.uuidString + ".json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public func save(_ record: ConversationRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(record).write(to: url(for: record.id), options: .atomic)
    }

    public func load(_ id: UUID) throws -> ConversationRecord {
        try Self.decoder.decode(ConversationRecord.self, from: Data(contentsOf: url(for: id)))
    }

    /// Все разговоры, свежие первыми. Повреждённые файлы пропускаются.
    public func list() -> [ConversationRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(ConversationRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func delete(_ id: UUID) throws {
        try FileManager.default.removeItem(at: url(for: id))
    }
}
