import Foundation

/// Держит один процесс агента и превращает его вывод в поток событий.
///
/// Один процесс обслуживает весь диалог: контекст сохраняется между ходами, `session_id`
/// не меняется. Перезапуск с `--resume` нужен только чтобы поднять сессию после того,
/// как процесс умер или приложение перезапустилось.
///
/// Потокобезопасность: весь изменяемый стейт живёт на одной последовательной очереди.
/// Пайпы отдают данные с произвольных потоков, поэтому порядок кусков сохраняет очередь,
/// а не приоритеты задач.
public final class AgentRuntime: @unchecked Sendable {

    public struct Configuration: Sendable {
        public var executable: URL
        public var arguments: [String]
        public var workingDirectory: URL?
        /// Окружение процесса. `nil` — унаследовать окружение приложения.
        public var environment: [String: String]?
        public var maximumLineLength: Int

        public init(
            executable: URL,
            arguments: [String],
            workingDirectory: URL? = nil,
            environment: [String: String]? = nil,
            maximumLineLength: Int = 8 * 1024 * 1024
        ) {
            self.executable = executable
            self.arguments = arguments
            self.workingDirectory = workingDirectory
            self.environment = environment
            self.maximumLineLength = maximumLineLength
        }
    }

    public enum Failure: LocalizedError, Sendable {
        case alreadyRunning
        case notRunning
        case launchFailed(String)
        case writeFailed(String)
        case streamCorrupted(NDJSONLineSplitter.Failure)

        // Эти строки видит пользователь в ленте чата.
        public var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                "Агент уже запущен."
            case .notRunning:
                "Агент не запущен. Попробуйте отправить сообщение ещё раз."
            case .launchFailed(let reason):
                "Не удалось запустить Claude Code: \(reason)"
            case .writeFailed(let reason):
                "Не удалось передать сообщение агенту: \(reason)"
            case .streamCorrupted:
                "Ответ агента пришёл повреждённым."
            }
        }
    }

    /// Запись в stdin умершего процесса поднимает SIGPIPE, который по умолчанию
    /// убивает всё приложение. Для GUI это мгновенная смерть без следов в логе,
    /// поэтому сигнал глушится один раз на процесс.
    private static let ignoreSIGPIPE: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    private let configuration: Configuration
    private let queue = DispatchQueue(label: "app.runie.AgentRuntime")

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var continuation: AsyncStream<RuntimeOutput>.Continuation?
    private var outputSplitter: NDJSONLineSplitter
    private var errorSplitter: NDJSONLineSplitter
    private var stopRequested = false

    /// Пока процесс жив, рантайм держит сам себя.
    ///
    /// Иначе `AgentRuntime(...).start()` отдавал бы поток, который молча никогда не
    /// закроется: временный объект умирает сразу после вызова, все обработчики
    /// захвачены слабо и не срабатывают. Ссылка снимается при завершении.
    private var selfRetain: AgentRuntime?

    /// Завершать поток можно только когда процесс вышел И оба пайпа отдали EOF.
    /// terminationHandler регулярно опережает последние куски вывода.
    private var processExited = false
    private var stdoutFinished = false
    private var stderrFinished = false
    private var exitStatus: Int32 = 0
    private var exitedBySignal = false

    public init(configuration: Configuration) {
        _ = Self.ignoreSIGPIPE
        self.configuration = configuration
        self.outputSplitter = NDJSONLineSplitter(maximumLineLength: configuration.maximumLineLength)
        self.errorSplitter = NDJSONLineSplitter(maximumLineLength: configuration.maximumLineLength)
    }

    deinit {
        process?.terminate()
    }

    public var isRunning: Bool {
        queue.sync { process?.isRunning ?? false }
    }

    /// Запускает процесс и возвращает поток его вывода.
    ///
    /// Поток закрывается после `terminated`. Повторный запуск того же рантайма
    /// не поддерживается: на новый диалог создаётся новый экземпляр.
    public func start() throws -> AsyncStream<RuntimeOutput> {
        try queue.sync {
            guard process == nil else { throw Failure.alreadyRunning }

            let process = Process()
            process.executableURL = configuration.executable
            process.arguments = configuration.arguments
            if let workingDirectory = configuration.workingDirectory {
                process.currentDirectoryURL = workingDirectory
            }
            if let environment = configuration.environment {
                process.environment = environment
            }

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let (stream, continuation) = AsyncStream<RuntimeOutput>.makeStream(
                bufferingPolicy: .unbounded
            )

            self.process = process
            self.stdinHandle = stdinPipe.fileHandleForWriting
            self.continuation = continuation
            self.selfRetain = self

            // Пустой кусок означает EOF. Обработчик после этого обязательно снять:
            // иначе он продолжает срабатывать вхолостую и жжёт процессорное время.
            stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard let self else { return }
                if data.isEmpty { handle.readabilityHandler = nil }
                queue.async {
                    if data.isEmpty {
                        self.stdoutFinished = true
                        self.finishIfReady()
                    } else {
                        self.ingestOutput(data)
                    }
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard let self else { return }
                if data.isEmpty { handle.readabilityHandler = nil }
                queue.async {
                    if data.isEmpty {
                        self.stderrFinished = true
                        self.finishIfReady()
                    } else {
                        self.ingestError(data)
                    }
                }
            }
            process.terminationHandler = { [weak self] process in
                guard let self else { return }
                let status = process.terminationStatus
                let bySignal = process.terminationReason == .uncaughtSignal
                queue.async {
                    self.exitStatus = status
                    self.exitedBySignal = bySignal
                    self.processExited = true
                    self.finishIfReady()
                }
            }

            do {
                try process.run()
            } catch {
                self.process = nil
                self.stdinHandle = nil
                self.continuation = nil
                self.selfRetain = nil
                continuation.finish()
                throw Failure.launchFailed(error.localizedDescription)
            }

            // Только отказ потребителя. На `.finished` реагировать нельзя: поток
            // завершает сам рантайм с очереди, и синхронный заход обратно был бы
            // дедлоком на ней же. Поэтому и `async`, а не `sync`.
            continuation.onTermination = { [weak self] reason in
                guard case .cancelled = reason, let self else { return }
                queue.async { self.terminateOnQueue() }
            }

            return stream
        }
    }

    /// Отправляет сообщение пользователя в stdin.
    public func send(_ message: UserMessage) throws {
        try write(try message.ndjsonLine())
    }

    /// Отправляет управляющий запрос в stdin.
    public func send(_ request: ControlRequest, requestID: String) throws {
        try write(try request.ndjsonLine(requestID: requestID))
    }

    /// Отправляет ответ на запрос разрешения в stdin.
    public func send(_ response: PermissionResponse) throws {
        try write(try response.ndjsonLine())
    }

    private func write(_ line: Data) throws {
        try queue.sync {
            guard let handle = stdinHandle, process?.isRunning == true else {
                throw Failure.notRunning
            }
            do {
                try handle.write(contentsOf: line)
            } catch {
                throw Failure.writeFailed(error.localizedDescription)
            }
        }
    }

    /// Закрывает stdin, не убивая процесс: агент дорабатывает текущий ход и выходит сам.
    public func finishInput() {
        queue.sync {
            try? stdinHandle?.close()
            stdinHandle = nil
        }
    }

    /// Останавливает процесс. Повторный вызов безвреден.
    public func stop() {
        queue.sync { terminateOnQueue() }
    }

    private func terminateOnQueue() {
        guard let process, process.isRunning else { return }
        stopRequested = true
        try? stdinHandle?.close()
        stdinHandle = nil
        process.terminate()
    }

    // MARK: - Очередь ввода-вывода

    private func ingestOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        do {
            for line in try outputSplitter.append(data) {
                emitOutputLine(line)
            }
        } catch let failure as NDJSONLineSplitter.Failure {
            continuation?.yield(.diagnostic("Поток stdout повреждён: \(failure)"))
        } catch {
            continuation?.yield(.diagnostic("Поток stdout повреждён: \(error)"))
        }
    }

    private func ingestError(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let lines = try? errorSplitter.append(data) else { return }
        for line in lines {
            continuation?.yield(.diagnostic(String(decoding: line, as: UTF8.self)))
        }
    }

    private func emitOutputLine(_ line: Data) {
        if let value = try? JSONValue.decode(line), case .object = value {
            continuation?.yield(.event(RawAgentEvent(payload: value)))
        } else {
            continuation?.yield(.malformedLine(String(decoding: line, as: UTF8.self)))
        }
    }

    /// Закрывает поток, когда собрались все три условия: процесс вышел и оба пайпа
    /// отдали EOF. Раньше нельзя — потеряется финальное событие `result`, а это
    /// единственный признак того, что ход завершён.
    private func finishIfReady() {
        guard processExited, stdoutFinished, stderrFinished, let continuation else { return }

        // Хвосты: процесс мог закрыть поток, не поставив последний перевод строки.
        if let tail = outputSplitter.flush() {
            emitOutputLine(tail)
        }
        if let tail = errorSplitter.flush() {
            continuation.yield(.diagnostic(String(decoding: tail, as: UTF8.self)))
        }

        let reason: RuntimeOutput.TerminationReason =
            stopRequested ? .stopped : (exitedBySignal ? .signalled : .exited)

        continuation.yield(.terminated(code: exitStatus, reason: reason))
        continuation.finish()

        self.continuation = nil
        stdinHandle = nil
        process = nil
        selfRetain = nil
    }
}
