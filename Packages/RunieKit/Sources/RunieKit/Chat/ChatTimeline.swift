import Foundation

/// Лента чата: то, что видит пользователь, без единой строчки UI.
///
/// Чистая модель. События агента применяются по одному, результат детерминирован,
/// поэтому вся логика ленты проверяется на фикстурах с живого CLI без запуска
/// приложения.
public struct ChatTimeline: Sendable, Equatable {

    /// Чем агент занят прямо сейчас.
    public enum Activity: Sendable, Equatable {
        case idle
        /// Сообщение отправлено, ответа ещё нет.
        case waiting
        case thinking
        /// Работает; строка — описание от самого агента, если оно пришло.
        case working(String?)
        case responding
    }

    public private(set) var items: [TimelineItem] = []
    public private(set) var activity: Activity = .idle
    public private(set) var usage: SubscriptionUsage?
    public private(set) var sessionID: String?

    // MARK: Потоковый текст

    /// Какое сообщение сейчас пишется, отдельно для основного агента и каждого
    /// субагента: их потоки идут вперемешку.
    private var currentMessage: [String: String] = [:]
    /// Блоки текста, напечатанные кусками и ещё не подтверждённые полным событием.
    private var streamingBlocks: [StreamKey: StreamingBlock] = [:]

    private struct StreamKey: Hashable, Sendable {
        let messageID: String
        let blockIndex: Int
    }

    private struct StreamingBlock: Equatable, Sendable {
        let itemID: UUID
        var text: String
    }

    public init() {}

    public var isBusy: Bool { activity != .idle }

    // MARK: - Действия пользователя

    public mutating func appendUserMessage(_ text: String, id: UUID = UUID()) {
        items.append(.user(UserItem(id: id, text: text)))
        activity = .waiting
    }

    /// Ошибка на стороне приложения, до того как агент что-то ответил.
    public mutating func recordLocalFailure(_ message: String) {
        items.append(.notice(NoticeItem(kind: .error, text: message)))
        interruptRunningActions()
        activity = .idle
    }

    // MARK: - События агента

    public mutating func apply(_ event: AgentEvent) {
        switch event {
        case .sessionStarted(let info):
            sessionID = info.sessionID

        case .assistantText(let text):
            if !confirmStreamedText(text) {
                appendAssistantText(text)
            }
            activity = .responding

        case .messageStarted(let messageID, let parent):
            currentMessage[parent ?? ""] = messageID

        case .textDelta(let delta):
            appendDelta(delta)
            activity = .responding

        case .thinking:
            activity = .thinking

        case .toolUse(let use):
            let description = ToolDescriber.describe(name: use.name, input: use.input)
            items.append(.action(ActionItem(
                id: use.id,
                toolName: use.name,
                title: description.title,
                detail: description.detail,
                status: .running,
                output: nil,
                isNested: use.parentToolUseID != nil
            )))
            activity = .working(nil)

        case .toolResult(let result):
            updateAction(result.toolUseID) { action in
                // Отказ важнее ошибки: результат после отказа — это сам текст отказа,
                // и перетирать им «отказано» значит потерять главное.
                if action.status != .denied {
                    action.status = result.isError ? .failed : .succeeded
                }
                action.output = result.text.isEmpty ? nil : result.text
            }

        case .permissionDenied(let denial):
            updateAction(denial.toolUseID) { action in
                action.status = .denied
                action.output = denial.message
            }

        case .progress(let detail):
            activity = .working(detail)

        case .subscriptionUsage(let usage):
            self.usage = usage

        case .turnCompleted:
            interruptRunningActions()
            resetStreaming()
            activity = .idle

        case .turnFailed(let failure):
            items.append(.notice(NoticeItem(
                kind: .error,
                text: failure.message ?? "Не получилось: \(failure.reason)"
            )))
            interruptRunningActions()
            resetStreaming()
            activity = .idle

        case .unknown:
            break
        }
    }

    /// Процесс агента завершился.
    public mutating func markConnectionEnded(exitCode: Int32, stoppedByUser: Bool) {
        if stoppedByUser {
            if isBusy {
                items.append(.notice(NoticeItem(kind: .info, text: "Остановлено")))
            }
        } else if isBusy || exitCode != 0 {
            items.append(.notice(NoticeItem(
                kind: .error,
                text: "Агент неожиданно завершился (код \(exitCode))"
            )))
        }
        interruptRunningActions()
        resetStreaming()
        activity = .idle
    }

    // MARK: - Внутреннее

    private mutating func appendDelta(_ delta: TextDelta) {
        // Кусок без известного сообщения склеить не с чем — ждём полного события.
        guard let messageID = currentMessage[delta.parentToolUseID ?? ""] else { return }
        let key = StreamKey(messageID: messageID, blockIndex: delta.blockIndex)

        if var block = streamingBlocks[key],
           let index = items.lastIndex(where: { $0.id == block.itemID.uuidString }),
           case .assistant(var item) = items[index] {
            item.text += delta.text
            block.text += delta.text
            items[index] = .assistant(item)
            streamingBlocks[key] = block
            return
        }

        // Новый блок. Второй текстовый блок того же сообщения без «рук» между ними
        // приклеивается к предыдущему — так же, как без потокового вывода.
        if case .assistant(var last) = items.last, last.messageID == messageID {
            last.text += "\n\n" + delta.text
            items[items.count - 1] = .assistant(last)
            streamingBlocks[key] = StreamingBlock(itemID: last.id, text: delta.text)
            return
        }

        let item = AssistantItem(messageID: messageID, text: delta.text)
        items.append(.assistant(item))
        streamingBlocks[key] = StreamingBlock(itemID: item.id, text: delta.text)
    }

    /// Полное событие пришло после кусков того же блока. Текст уже в ленте:
    /// дописывать его второй раз нельзя. Если напечатанное разошлось с полным
    /// текстом — например, потерялся кусок, — хвост реплики заменяется полным.
    ///
    /// Возвращает `false`, если сопоставить не с чем: тогда текст добавляется как обычно.
    private mutating func confirmStreamedText(_ text: AssistantText) -> Bool {
        guard let messageID = text.messageID else { return false }

        // Полное событие приходит до конца блока, поэтому подтверждаемый блок —
        // самый ранний неподтверждённый в этом сообщении.
        let candidates = streamingBlocks
            .filter { $0.key.messageID == messageID }
            .sorted { $0.key.blockIndex < $1.key.blockIndex }
        guard let (key, block) = candidates.first(where: { $0.value.text == text.text }) ?? candidates.first
        else { return false }

        streamingBlocks[key] = nil
        guard block.text != text.text,
              let index = items.lastIndex(where: { $0.id == block.itemID.uuidString }),
              case .assistant(var item) = items[index]
        else { return true }

        if item.text.hasSuffix(block.text) {
            item.text = String(item.text.dropLast(block.text.count)) + text.text
        } else {
            item.text = text.text
        }
        items[index] = .assistant(item)
        return true
    }

    private mutating func resetStreaming() {
        currentMessage.removeAll()
        streamingBlocks.removeAll()
    }

    private mutating func appendAssistantText(_ text: AssistantText) {
        // Несколько текстовых блоков одного сообщения идут подряд — склеиваем их.
        // Если между ними были «руки», текст начинается заново после них.
        if let messageID = text.messageID,
           case .assistant(var last) = items.last,
           last.messageID == messageID {
            last.text += "\n\n" + text.text
            items[items.count - 1] = .assistant(last)
            return
        }
        items.append(.assistant(AssistantItem(messageID: text.messageID, text: text.text)))
    }

    private mutating func updateAction(_ id: String, _ change: (inout ActionItem) -> Void) {
        guard let index = items.lastIndex(where: { $0.id == id }),
              case .action(var action) = items[index]
        else { return }
        change(&action)
        items[index] = .action(action)
    }

    private mutating func interruptRunningActions() {
        for index in items.indices {
            if case .action(var action) = items[index], action.status == .running {
                action.status = .interrupted
                items[index] = .action(action)
            }
        }
    }
}

// MARK: - Элементы ленты

public enum TimelineItem: Sendable, Equatable, Identifiable {
    case user(UserItem)
    case assistant(AssistantItem)
    case action(ActionItem)
    case notice(NoticeItem)

    public var id: String {
        switch self {
        case .user(let item): item.id.uuidString
        case .assistant(let item): item.id.uuidString
        case .action(let item): item.id
        case .notice(let item): item.id.uuidString
        }
    }
}

public struct UserItem: Sendable, Equatable {
    public let id: UUID
    public let text: String
}

public struct AssistantItem: Sendable, Equatable {
    public let id: UUID
    public let messageID: String?
    public var text: String

    init(id: UUID = UUID(), messageID: String?, text: String) {
        self.id = id
        self.messageID = messageID
        self.text = text
    }
}

public struct ActionItem: Sendable, Equatable {

    public enum Status: Sendable, Equatable {
        case running
        case succeeded
        case failed
        /// В разрешении отказано.
        case denied
        /// Ход закончился, а результата так и не пришло.
        case interrupted
    }

    /// Идентификатор вызова инструмента из CLI.
    public let id: String
    public let toolName: String
    public let title: String
    public let detail: String?
    public var status: Status
    public var output: String?
    /// Действие субагента, а не основного агента.
    public let isNested: Bool
}

public struct NoticeItem: Sendable, Equatable {

    public enum Kind: Sendable, Equatable {
        case info
        case error
    }

    public let id: UUID
    public let kind: Kind
    public let text: String

    init(id: UUID = UUID(), kind: Kind, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}
