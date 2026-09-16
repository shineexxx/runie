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
    func send(_ text: String) throws
    /// Отвечает на запрос разрешения. Агент ждёт этого ответа и без него не продолжит.
    func respond(to request: PermissionRequest, with decision: PermissionDecision) throws
    /// Управляющий запрос. Ответ придёт событием `controlResponse` с тем же идентификатором.
    func send(_ request: ControlRequest, requestID: String) throws
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
    func connect(resuming sessionID: String?) throws -> AgentConnectionHandle
}

// MARK: - Claude Code

public struct ClaudeCodeBackend: AgentBackend {

    public var executable: URL
    public var workingDirectory: URL?
    /// Базовые аргументы. Поле `session` перезаписывается при каждом подключении.
    public var arguments: ClaudeCodeArguments

    public init(
        executable: URL,
        workingDirectory: URL? = nil,
        arguments: ClaudeCodeArguments = ClaudeCodeArguments()
    ) {
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.arguments = arguments
    }

    public func connect(resuming sessionID: String?) throws -> AgentConnectionHandle {
        var arguments = self.arguments
        arguments.session = sessionID.map { .resume(id: $0) } ?? .new(id: UUID())

        let runtime = AgentRuntime(configuration: .init(
            executable: executable,
            arguments: arguments.build(),
            workingDirectory: workingDirectory
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

    func send(_ text: String) throws {
        try runtime.send(UserMessage(text))
    }

    func respond(to request: PermissionRequest, with decision: PermissionDecision) throws {
        try runtime.send(PermissionResponse(request: request, decision: decision))
    }

    func send(_ request: ControlRequest, requestID: String) throws {
        try runtime.send(request, requestID: requestID)
    }

    func stop() {
        runtime.stop()
    }
}
