import Foundation

/// Придумывает подсказки разовым запросом к Claude Code, отдельно от разговора.
///
/// Запрос лёгкий: быстрая модель, без инструментов, без MCP, без настроек и хуков
/// пользователя, со своим коротким системным промптом и без сохранения сессии.
/// Так он стоит порядка тысячи токенов и не попадает в историю Claude Code.
public struct ClaudeSuggestionGenerator: Sendable {

    public var executable: URL
    public var model: String
    public var timeout: Duration

    public init(executable: URL, model: String = "haiku", timeout: Duration = .seconds(90)) {
        self.executable = executable
        self.model = model
        self.timeout = timeout
    }

    public enum Failure: Error, Equatable {
        case processFailed(Int32)
        case emptyAnswer
        case timedOut
    }

    public func arguments(for context: SuggestionContext) -> [String] {
        [
            "--print",
            "--model", model,
            "--tools", "",
            "--strict-mcp-config",
            "--setting-sources", "",
            "--no-session-persistence",
            "--disable-slash-commands",
            "--system-prompt", "Ты придумываешь короткие подсказки для ИИ-помощника на Mac. Отвечай только JSON.",
            "--output-format", "json",
            context.prompt()
        ]
    }

    public func generate(_ context: SuggestionContext) async throws -> SuggestionSet {
        let arguments = arguments(for: context)
        let executable = executable
        let timeout = timeout

        return try await withThrowingTaskGroup(of: SuggestionSet.self) { group in
            group.addTask {
                let output = try await Self.run(executable: executable, arguments: arguments)
                // Итог хода — в поле result; если JSON вокруг не разобрался, пробуем весь вывод.
                let result = (try? JSONValue.decode(Data(output.utf8)))?["result"]?.stringValue ?? output
                let set = SuggestionParser.parseSet(result)
                guard !set.suggestions.isEmpty else { throw Failure.emptyAnswer }
                return set
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Failure.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next() ?? SuggestionSet(greeting: nil, suggestions: [])
        }
    }

    private static func run(executable: URL, arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // Пустая временная папка: CLAUDE.md и настройки проекта не подмешиваются.
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    let data = stdout.fileHandleForReading.readDataToEndOfFile()
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: String(decoding: data, as: UTF8.self))
                    } else {
                        continuation.resume(throwing: Failure.processFailed(process.terminationStatus))
                    }
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
