import Foundation

/// Краткая сводка из одного MCP-сервера для подсказок.
///
/// Отдельная короткая сессия Claude Code: быстрая модель, без встроенных
/// инструментов, без сохранения. Вопросы о разрешении отвечает сам Runie — пускает
/// только читающие инструменты этого сервера (`ReadOnlyTools`), всё остальное
/// отклоняет. Человеку ничего не показывается.
public struct MCPDigest: Sendable {

    public let backend: any AgentBackend
    public let timeout: Duration

    public init(backend: any AgentBackend, timeout: Duration = .seconds(90)) {
        self.backend = backend
        self.timeout = timeout
    }

    /// Аргументы для такой сессии поверх обычных.
    public static func arguments(model: String = "haiku") -> [String] {
        // Не `--tools ""`: он выключает и инструменты MCP. Встроенные запрещаем списком.
        [
            "--model", model,
            "--disallowedTools", builtInTools.joined(separator: ","),
            "--no-session-persistence",
            "--disable-slash-commands",
            "--system-prompt", """
            Ты собираешь краткую сводку для ИИ-помощника на Mac. Используй только инструменты, \
            которые читают данные. Ничего не отправляй и не меняй. Ответь по-русски списком \
            до 5 коротких пунктов, только суть: кто, что, название. Если ничего подходящего нет — ответь ровно одним словом «нет», \
            не объясняя, что и где проверял.
            """
        ]
    }

    static let builtInTools = [
        "Bash", "Read", "Write", "Edit", "MultiEdit", "NotebookEdit", "Glob", "Grep", "LS",
        "WebFetch", "WebSearch", "Task", "Agent", "TodoWrite", "Skill"
    ]

    public func collect(server: String, query: String, log: (@Sendable (String) -> Void)? = nil) async -> String? {
        let handle: AgentConnectionHandle
        do {
            handle = try backend.connect(resuming: nil, disallowedTools: [])
        } catch {
            return nil
        }
        let connection = handle.connection
        // Сервер подключается не сразу (коннекторам claude.ai нужно секунд восемь),
        // а инструменты в сессии — только у подключённых. Спрашиваем, пока не готов.
        let statusID = "digest-status"
        do {
            try connection.send(.initialize, requestID: "digest-init")
            try connection.send(.mcpStatus, requestID: statusID)
        } catch {
            connection.stop()
            return nil
        }
        let message = UserMessage("Сервис «\(server)». Что собрать: \(query)")

        let result = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                var text = ""
                var asked = false
                for await item in handle.stream {
                    guard case .event(let event) = item else { continue }
                    switch event {
                    case .controlResponse(let response) where response.requestID == statusID && !asked:
                        let status = MCPServerInfo.list(from: response.body).first { $0.name == server }?.status
                        switch status {
                        case .connected?:
                            asked = true
                            try? connection.send(message)
                        case .pending?:
                            try? await Task.sleep(for: .seconds(1))
                            try? connection.send(.mcpStatus, requestID: statusID)
                        default:
                            // Сервера нет, он выключен или ждёт входа — собирать нечего.
                            return nil
                        }
                    case .permissionRequested(let request):
                        let allowed = ReadOnlyTools.allows(toolName: request.toolName, server: server)
                        log?("\(allowed ? "разрешено" : "запрещено"): \(request.toolName)")
                        try? connection.respond(
                            to: request,
                            with: allowed ? .allow : .deny(message: "При сборе сводки можно только читать.")
                        )
                    case .assistantText(let chunk) where chunk.parentToolUseID == nil:
                        text = chunk.text
                    case .turnCompleted:
                        return text
                    case .turnFailed:
                        return nil
                    default:
                        break
                    }
                }
                return text.isEmpty ? nil : text
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        connection.stop()

        return Self.meaningful(result)
    }

    /// Сводка, если в ней что-то есть. «нет», «**нет**», «Нет.» и пояснения вроде
    /// «Нет страниц за сутки: проверил 10…» без единого пункта — пусто: генератору
    /// подсказок они только мешают.
    static func meaningful(_ result: String?) -> String? {
        guard let summary = result?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else { return nil }
        let bare = summary.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "*_.!: ").union(.whitespacesAndNewlines))
        guard bare != "нет" else { return nil }
        let hasItems = summary.split(separator: "\n").contains {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("- ") || line.hasPrefix("• ") || line.hasPrefix("* ") || line.first?.isNumber == true
        }
        if !hasItems, bare.hasPrefix("нет ") || bare.hasPrefix("ничего") { return nil }
        return summary
    }
}
