import Foundation

/// Что приходит из соединения с агентом. Интерфейс видит только это.
public enum AgentStreamItem: Sendable, Equatable {
    case event(AgentEvent)
    /// Служебный вывод: stderr процесса или мусорная строка stdout. Пользователю
    /// не показывается, нужен для отладки.
    case diagnostic(String)
    /// Процесс агента завершился. Следующее сообщение поднимает новое соединение.
    case ended(exitCode: Int32, stoppedByUser: Bool)
}

/// Живое соединение с агентом.
public protocol AgentConnection: AnyObject, Sendable {
    func send(_ message: UserMessage) throws
    /// Отвечает на запрос разрешения. Агент ждёт этого ответа и без него не продолжит.
    func respond(to request: PermissionRequest, with decision: PermissionDecision) throws
    /// Управляющий запрос. Ответ придёт событием `controlResponse` с тем же идентификатором.
    func send(_ request: ControlRequest, requestID: String) throws
    /// Ответ встроенного MCP-сервера на `mcpMessage`.
    func respondToMCP(_ reply: MCPReply) throws
    func stop()
}

public struct AgentConnectionHandle: Sendable {
    public let connection: any AgentConnection
    public let stream: AsyncStream<AgentStreamItem>

    public init(connection: any AgentConnection, stream: AsyncStream<AgentStreamItem>) {
        self.connection = connection
        self.stream = stream
    }
}

/// Граница между приложением и конкретным агентским CLI.
///
/// Всё, что специфично для Claude Code, живёт за этим протоколом: флаги, форма
/// потока, способ продолжить сессию. Если Anthropic поменяет правила для `claude -p`,
/// появится ещё одна реализация, а интерфейс и модель чата не изменятся.
public protocol AgentBackend: Sendable {
    /// Поднимает соединение. `sessionID` — продолжить существующую сессию.
    /// `disallowedTools` — правила запрета на эту сессию, например `Skill(имя)`.
    func connect(resuming sessionID: String?, disallowedTools: [String]) throws -> AgentConnectionHandle
}

// MARK: - Claude Code

public struct ClaudeCodeBackend: AgentBackend {

    public var executable: URL
    public var workingDirectory: URL?
    /// Базовые аргументы. Поле `session` перезаписывается при каждом подключении.
    public var arguments: ClaudeCodeArguments
    /// Переменные, которые добавляются к окружению приложения при каждом подключении:
    /// ключи серверов из Связки ключей, более полный PATH. Считаются заново — ключ,
    /// введённый минуту назад, уже на месте.
    public var extraEnvironment: (@Sendable () -> [String: String])?

    public init(
        executable: URL,
        workingDirectory: URL? = nil,
        arguments: ClaudeCodeArguments = ClaudeCodeArguments()
    ) {
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.arguments = arguments
    }

    public func connect(resuming sessionID: String?, disallowedTools: [String]) throws -> AgentConnectionHandle {
        var arguments = self.arguments
        arguments.session = sessionID.map { .resume(id: $0) } ?? .new(id: UUID())
        arguments.disallowedTools += disallowedTools

        let runtime = AgentRuntime(configuration: .init(
            executable: executable,
            arguments: arguments.build(),
            workingDirectory: workingDirectory,
            environment: extraEnvironment.map { extra in
                ProcessInfo.processInfo.environment.merging(extra()) { _, new in new }
            }
        ))
        let raw = try runtime.start()
        let normalizer = AgentEventNormalizer()

        let stream = AsyncStream<AgentStreamItem> { continuation in
            let pump = Task {
                for await output in raw {
                    switch output {
                    case .event(let event):
                        for normalized in normalizer.normalize(event) {
                            continuation.yield(.event(normalized))
                        }
                    case .malformedLine(let line):
                        continuation.yield(.diagnostic("stdout: \(line)"))
                    case .diagnostic(let line):
                        continuation.yield(.diagnostic(line))
                    case .terminated(let code, let reason):
                        continuation.yield(.ended(exitCode: code, stoppedByUser: reason == .stopped))
                    }
                }
                continuation.finish()
            }
            // Отмена чтения прекращает перебор сырого потока, а его отмена
            // останавливает процесс внутри рантайма.
            continuation.onTermination = { _ in pump.cancel() }
        }

        return AgentConnectionHandle(connection: ClaudeCodeConnection(runtime: runtime), stream: stream)
    }
}

final class ClaudeCodeConnection: AgentConnection {
    private let runtime: AgentRuntime

    init(runtime: AgentRuntime) {
        self.runtime = runtime
    }

    func send(_ message: UserMessage) throws {
        try runtime.send(message)
    }

    func respond(to request: PermissionRequest, with decision: PermissionDecision) throws {
        try runtime.send(PermissionResponse(request: request, decision: decision))
    }

    func send(_ request: ControlRequest, requestID: String) throws {
        try runtime.send(request, requestID: requestID)
    }

    func respondToMCP(_ reply: MCPReply) throws {
        try runtime.send(reply)
    }

    func stop() {
        runtime.stop()
    }
}
