import Foundation

/// Превращает сырые события Claude Code в события приложения.
///
/// Формы событий сняты с настоящего CLI, фикстуры лежат в тестах. Общие правила:
///
/// - Одно сырое событие даёт ноль, одно или несколько событий приложения:
///   сообщение ассистента несёт несколько блоков подряд.
/// - Нехватка поля не роняет разбор. Если событие известного типа не удалось
///   разобрать, оно уходит как `.unknown`, а не пропадает молча.
/// - Шумовые события, которые интерфейсу не нужны, отбрасываются явно и перечислены
///   в одном месте.
public struct AgentEventNormalizer: Sendable {

    /// События, которые интерфейсу не нужны. Перечислены явно, чтобы новый
    /// незнакомый тип не потерялся среди них, а пришёл как `.unknown`.
    public static let ignoredSystemSubtypes: Set<String> = [
        // Служебные события хуков пользователя. Их вывод принадлежит чужому коду.
        "hook_started",
        "hook_response",
        // Сводка хода для внутреннего пользования CLI; итог хода приходит в result.
        "post_turn_summary",
        // «requesting» — запрос к модели ушёл. Лента узнаёт об этом раньше,
        // в момент отправки сообщения.
        "status",
        // Счётчик токенов размышления. Сам факт размышления приходит блоком thinking.
        "thinking_tokens"
    ]

    public init() {}

    public func normalize(_ event: RawAgentEvent) -> [AgentEvent] {
        let payload = event.payload

        switch event.type {
        case "system":
            return normalizeSystem(event)
        case "assistant":
            return normalizeAssistant(payload) ?? [.unknown(event)]
        case "user":
            return normalizeUser(payload) ?? [.unknown(event)]
        case "rate_limit_event":
            return normalizeRateLimit(payload).map { [$0] } ?? [.unknown(event)]
        case "result":
            return [normalizeResult(event)]
        case "stream_event":
            return normalizeStreamEvent(payload) ?? [.unknown(event)]
        case "control_request":
            return normalizeControlRequest(payload).map { [$0] } ?? [.unknown(event)]
        case "control_response":
            guard let response = payload["response"],
                  let requestID = response["request_id"]?.stringValue
            else { return [.unknown(event)] }
            return [.controlResponse(ControlResponse(
                requestID: requestID,
                isSuccess: response["subtype"]?.stringValue == "success",
                body: response["response"],
                error: response["error"]?.stringValue
            ))]
        case "control_cancel_request":
            guard let requestID = payload["request_id"]?.stringValue else { return [.unknown(event)] }
            return [.permissionRequestCancelled(requestID: requestID)]
        default:
            return [.unknown(event)]
        }
    }

    // MARK: - system

    private func normalizeSystem(_ event: RawAgentEvent) -> [AgentEvent] {
        let payload = event.payload
        guard let subtype = event.subtype else { return [.unknown(event)] }
        if Self.ignoredSystemSubtypes.contains(subtype) { return [] }

        switch subtype {
        case "init":
            guard let sessionID = event.sessionID else { return [.unknown(event)] }
            let tools = payload["tools"]?.arrayValue?.compactMap(\.stringValue) ?? []
            var info = SessionInfo(
                sessionID: sessionID,
                model: payload["model"]?.stringValue,
                tools: tools,
                workingDirectory: payload["cwd"]?.stringValue,
                permissionMode: payload["permissionMode"]?.stringValue,
                cliVersion: payload["claude_code_version"]?.stringValue
            )
            info.skills = payload["skills"]?.arrayValue?.compactMap(\.stringValue) ?? []
            info.plugins = (payload["plugins"]?.arrayValue ?? []).compactMap { plugin in
                guard let name = plugin["name"]?.stringValue, let path = plugin["path"]?.stringValue else { return nil }
                return PluginInfo(name: name, path: path)
            }
            return [.sessionStarted(info)]

        case "permission_denied":
            guard let toolUseID = payload["tool_use_id"]?.stringValue,
                  let toolName = payload["tool_name"]?.stringValue
            else { return [.unknown(event)] }
            return [.permissionDenied(PermissionDenial(
                toolUseID: toolUseID,
                toolName: toolName,
                message: payload["message"]?.stringValue ?? ""
            ))]

        case "task_summary":
            guard let detail = payload["detail"]?.stringValue, !detail.isEmpty else { return [] }
            return [.progress(detail)]

        default:
            return [.unknown(event)]
        }
    }

    // MARK: - assistant

    private func normalizeAssistant(_ payload: JSONValue) -> [AgentEvent]? {
        guard let blocks = payload.path("message", "content")?.arrayValue else { return nil }
        let messageID = payload.path("message", "id")?.stringValue
        let parent = payload["parent_tool_use_id"]?.stringValue

        return blocks.compactMap { block -> AgentEvent? in
            switch block["type"]?.stringValue {
            case "text":
                guard let text = block["text"]?.stringValue, !text.isEmpty else { return nil }
                return .assistantText(AssistantText(
                    text: text,
                    messageID: messageID,
                    parentToolUseID: parent
                ))

            case "thinking", "redacted_thinking":
                return .thinking(parentToolUseID: parent)

            case "tool_use", "server_tool_use":
                guard let id = block["id"]?.stringValue,
                      let name = block["name"]?.stringValue
                else { return nil }
                return .toolUse(ToolUse(
                    id: id,
                    name: name,
                    input: block["input"] ?? .object([:]),
                    parentToolUseID: parent
                ))

            default:
                return nil
            }
        }
    }

    // MARK: - user

    /// В потоке `user` приходят результаты инструментов. Текст самого пользователя
    /// приложение знает и так, поэтому он отбрасывается.
    private func normalizeUser(_ payload: JSONValue) -> [AgentEvent]? {
        let content = payload.path("message", "content")
        if content?.stringValue != nil { return [] }
        guard let blocks = content?.arrayValue else { return nil }
        let parent = payload["parent_tool_use_id"]?.stringValue

        return blocks.compactMap { block -> AgentEvent? in
            guard block["type"]?.stringValue == "tool_result",
                  let toolUseID = block["tool_use_id"]?.stringValue
            else { return nil }
            return .toolResult(ToolResult(
                toolUseID: toolUseID,
                isError: block["is_error"]?.boolValue ?? false,
                text: Self.flattenToolResultContent(block["content"]),
                parentToolUseID: parent
            ))
        }
    }

    /// Содержимое результата бывает строкой или массивом блоков.
    static func flattenToolResultContent(_ content: JSONValue?) -> String {
        switch content {
        case .string(let text):
            return text
        case .array(let blocks):
            return blocks.compactMap { block -> String? in
                switch block["type"]?.stringValue {
                case "text": block["text"]?.stringValue
                case "image": "[изображение]"
                case .some(let other): "[\(other)]"
                case .none: nil
                }
            }
            .joined(separator: "\n")
        default:
            return ""
        }
    }

    // MARK: - control_request

    /// Запрос от CLI к приложению. Пока понимаем только вопрос о разрешении: другие
    /// запросы приходят, лишь когда хост сам их заказал, а Runie их не заказывает.
    private func normalizeControlRequest(_ payload: JSONValue) -> AgentEvent? {
        if let requestID = payload["request_id"]?.stringValue,
           let request = payload["request"],
           request["subtype"]?.stringValue == "mcp_message",
           let server = request["server_name"]?.stringValue,
           let message = request["message"] {
            return .mcpMessage(MCPMessage(requestID: requestID, serverName: server, message: message))
        }
        guard let requestID = payload["request_id"]?.stringValue,
              let request = payload["request"],
              request["subtype"]?.stringValue == "can_use_tool",
              let toolName = request["tool_name"]?.stringValue
        else { return nil }
        return .permissionRequested(PermissionRequest(
            requestID: requestID,
            toolUseID: request["tool_use_id"]?.stringValue,
            toolName: toolName,
            input: request["input"] ?? .object([:]),
            reason: request["decision_reason"]?.stringValue
        ))
    }

    // MARK: - stream_event

    /// Куски, которые CLI отдаёт с `--include-partial-messages`. Внутри — события
    /// потокового API как есть. Интерфейсу нужны только начало сообщения и куски
    /// текста; куски аргументов инструментов не нужны — полный вызов приходит
    /// следом одним событием `assistant`.
    private func normalizeStreamEvent(_ payload: JSONValue) -> [AgentEvent]? {
        guard let inner = payload["event"], let kind = inner["type"]?.stringValue else { return nil }
        let parent = payload["parent_tool_use_id"]?.stringValue

        switch kind {
        case "message_start":
            guard let id = inner.path("message", "id")?.stringValue else { return nil }
            return [.messageStarted(messageID: id, parentToolUseID: parent)]

        case "content_block_start":
            // Размышление видно заранее — индикатор «думает» загорается сразу.
            let blockType = inner.path("content_block", "type")?.stringValue
            return blockType == "thinking" ? [.thinking(parentToolUseID: parent)] : []

        case "content_block_delta":
            guard inner.path("delta", "type")?.stringValue == "text_delta" else { return [] }
            guard let index = inner["index"]?.intValue,
                  let text = inner.path("delta", "text")?.stringValue
            else { return nil }
            return text.isEmpty ? [] : [.textDelta(TextDelta(blockIndex: index, text: text, parentToolUseID: parent))]

        case "content_block_stop", "message_delta", "message_stop", "ping":
            return []

        default:
            return nil
        }
    }

    // MARK: - rate_limit_event

    private func normalizeRateLimit(_ payload: JSONValue) -> AgentEvent? {
        guard let info = payload["rate_limit_info"] else { return nil }

        let windows = (info["unifiedWindows"]?.objectValue ?? [:])
            .compactMap { kind, window -> SubscriptionUsage.Window? in
                guard let utilization = window["utilization"]?.doubleValue else { return nil }
                return SubscriptionUsage.Window(
                    kind: kind,
                    utilization: utilization,
                    resetsAt: window["resetsAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
                )
            }
            .sorted { $0.kind < $1.kind }

        return .subscriptionUsage(SubscriptionUsage(
            status: info["status"]?.stringValue ?? "unknown",
            windows: windows
        ))
    }

    // MARK: - result

    private func normalizeResult(_ event: RawAgentEvent) -> AgentEvent {
        let payload = event.payload
        let subtype = event.subtype ?? ""
        let isError = payload["is_error"]?.boolValue ?? false

        if subtype == "success" && !isError {
            return .turnCompleted(TurnSummary(
                result: payload["result"]?.stringValue,
                durationMilliseconds: payload["duration_ms"]?.intValue,
                costUSD: payload["total_cost_usd"]?.doubleValue,
                turnCount: payload["num_turns"]?.intValue,
                permissionDenialCount: payload["permission_denials"]?.arrayValue?.count ?? 0
            ))
        }

        let errors = payload["errors"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let message = errors.isEmpty ? payload["result"]?.stringValue : errors.joined(separator: "\n")
        return .turnFailed(TurnFailure(
            reason: subtype.isEmpty ? "error" : subtype,
            message: message
        ))
    }
}
