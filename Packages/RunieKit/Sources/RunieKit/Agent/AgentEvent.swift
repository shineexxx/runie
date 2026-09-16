import Foundation

/// Событие агента в терминах приложения.
///
/// Интерфейс рисует только это, а не сырой JSON. Всё знание о форме потока Claude Code
/// живёт в `AgentEventNormalizer`; когда CLI поменяет формат, меняется нормализатор,
/// а не вьюхи.
public enum AgentEvent: Sendable, Equatable {
    /// Сессия поднялась: известен идентификатор, модель и доступные инструменты.
    case sessionStarted(SessionInfo)
    /// Кусок ответа ассистента.
    ///
    /// При потоковом выводе этот же текст уже пришёл раньше кусками через `textDelta`.
    /// Сопоставлять их — задача ленты: нормализатор видит одно событие за раз.
    case assistantText(AssistantText)
    /// Модель начала новое сообщение. Куски текста идентификатор сообщения не несут,
    /// поэтому его надо запомнить здесь.
    case messageStarted(messageID: String, parentToolUseID: String?)
    /// Очередной кусок текста, пока модель ещё пишет.
    case textDelta(TextDelta)
    /// Ассистент размышлял. Содержимое CLI обычно не отдаёт, но сам факт полезен
    /// для индикатора «думает».
    case thinking(parentToolUseID: String?)
    /// Ассистент вызвал инструмент. Это и есть «руки» в интерфейсе.
    case toolUse(ToolUse)
    /// Инструмент вернул результат.
    case toolResult(ToolResult)
    /// CLI сам отказал в разрешении на вызов инструмента.
    case permissionDenied(PermissionDenial)
    /// CLI спрашивает, можно ли вызвать инструмент, и ждёт ответа приложения.
    /// Пока ответа нет, агент стоит.
    case permissionRequested(PermissionRequest)
    /// Вопрос о разрешении снят самим CLI: ответ больше не нужен.
    case permissionRequestCancelled(requestID: String)
    /// Короткое описание того, чем агент занят прямо сейчас.
    case progress(String)
    /// Остаток подписки.
    case subscriptionUsage(SubscriptionUsage)
    /// Ход завершён.
    case turnCompleted(TurnSummary)
    /// Ход не удался.
    ///
    /// Причину CLI кладёт в массив `errors` события и дублирует в stderr.
    case turnFailed(TurnFailure)
    /// Событие, которое нормализатор не знает. Не ошибка: CLI добавляет новые типы
    /// регулярно, и приложение не должно от этого ломаться.
    case unknown(RawAgentEvent)
}

public struct SessionInfo: Sendable, Equatable {
    public let sessionID: String
    public let model: String?
    public let tools: [String]
    public let workingDirectory: String?
    public let permissionMode: String?
    public let cliVersion: String?
}

public struct AssistantText: Sendable, Equatable {
    public let text: String
    public let messageID: String?
    /// Не `nil`, если текст написал субагент, запущенный этим вызовом инструмента.
    public let parentToolUseID: String?
}

public struct TextDelta: Sendable, Equatable {
    /// Номер блока внутри сообщения.
    public let blockIndex: Int
    public let text: String
    /// Не `nil` для субагента: у него свой поток сообщений, идущий вперемешку с основным.
    public let parentToolUseID: String?
}

public struct ToolUse: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let input: JSONValue
    public let parentToolUseID: String?
}

public struct ToolResult: Sendable, Equatable {
    public let toolUseID: String
    public let isError: Bool
    /// Текстовое содержимое результата. Нетекстовые блоки заменены пометками.
    public let text: String
    public let parentToolUseID: String?
}

public struct PermissionDenial: Sendable, Equatable {
    public let toolUseID: String
    public let toolName: String
    public let message: String
}

public struct PermissionRequest: Sendable, Equatable, Identifiable {
    /// Идентификатор запроса. На него ссылается ответ.
    public let requestID: String
    /// Вызов инструмента, о котором спрашивают. Совпадает с `ToolUse.id`.
    public let toolUseID: String?
    public let toolName: String
    public let input: JSONValue
    /// Почему CLI спрашивает, если он объяснил.
    public let reason: String?

    public var id: String { requestID }

    public init(requestID: String, toolUseID: String?, toolName: String, input: JSONValue, reason: String?) {
        self.requestID = requestID
        self.toolUseID = toolUseID
        self.toolName = toolName
        self.input = input
        self.reason = reason
    }
}

/// Ответ приложения на запрос разрешения.
public enum PermissionDecision: Sendable, Equatable {
    case allow
    case deny(message: String)
}

public struct SubscriptionUsage: Sendable, Equatable {

    public struct Window: Sendable, Equatable {
        /// Имя окна как его отдаёт CLI: `five_hour`, `seven_day` и так далее.
        public let kind: String
        /// Доля использования от 0 до 1.
        public let utilization: Double
        public let resetsAt: Date?
    }

    /// `allowed`, `allowed_warning`, `rejected` и так далее.
    public let status: String
    /// Окна отсортированы по имени, чтобы порядок не зависел от словаря в JSON.
    public let windows: [Window]

    public func window(_ kind: String) -> Window? {
        windows.first { $0.kind == kind }
    }
}

public struct TurnSummary: Sendable, Equatable {
    public let result: String?
    public let durationMilliseconds: Int?
    public let costUSD: Double?
    public let turnCount: Int?
    public let permissionDenialCount: Int
}

public struct TurnFailure: Sendable, Equatable {
    /// Подтип результата, например `error_during_execution` или `error_max_turns`.
    public let reason: String
    /// Текст ошибки, если CLI положил его в само событие.
    public let message: String?
}
