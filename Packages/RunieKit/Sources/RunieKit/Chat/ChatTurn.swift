import Foundation

/// Ход разговора: сообщение человека и всё, что Руни сделал в ответ. Компактный
/// чат показывает ходы облачками: прошлые — только реплики, текущий — ещё и «руки».
public struct ChatTurn: Identifiable, Equatable, Sendable {
    public let id: String
    /// Сообщение человека. Нет у хода, с которого лента началась без него.
    public let user: UserItem?
    public let lastAction: ActionItem?
    /// Последний текст Руни в этом ходе.
    public let reply: String?
    public let lastNotice: NoticeItem?

    /// Ход закончился ошибкой: после неё Руни уже ничего не написал.
    public var failure: NoticeItem? {
        guard let lastNotice, lastNotice.kind == .error else { return nil }
        return lastNotice
    }

    public static func split(_ items: [TimelineItem]) -> [ChatTurn] {
        var turns: [ChatTurn] = []
        var start = 0
        for (index, item) in items.enumerated() {
            if case .user = item, index > start {
                turns.append(ChatTurn(items[start..<index]))
                start = index
            }
        }
        if start < items.count {
            turns.append(ChatTurn(items[start...]))
        }
        return turns
    }

    init(_ items: ArraySlice<TimelineItem>) {
        id = items.first?.id ?? UUID().uuidString
        var user: UserItem?
        var action: ActionItem?
        var reply: String?
        var notice: NoticeItem?
        for item in items {
            switch item {
            case .user(let value): user = value
            case .action(let value): action = value
            // Ошибка, после которой Руни всё же ответил, — уже не итог хода.
            case .assistant(let value):
                reply = value.text
                if notice?.kind == .error { notice = nil }
            case .notice(let value): notice = value
            }
        }
        self.user = user
        lastAction = action
        self.reply = reply
        lastNotice = notice
    }
}

extension ChatSession {

    /// Последнее сообщение человека — для «Повторить» и стрелки вверх в пустом поле.
    /// Вложения, которых уже нет на диске, отбрасываются.
    public var lastUserMessage: (text: String, attachments: [Attachment])? {
        for item in timeline.items.reversed() {
            if case .user(let user) = item {
                let files = (user.attachments ?? []).filter { FileManager.default.fileExists(atPath: $0.path) }
                return (user.text, files)
            }
        }
        return nil
    }

    /// Отправляет последнее сообщение ещё раз.
    public func retry(context: AppContext? = nil) {
        guard let last = lastUserMessage else { return }
        send(last.text, context: context, attachments: last.attachments)
    }
}
