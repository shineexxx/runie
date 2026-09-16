import Foundation
import Observation

/// Модель чата для интерфейса.
///
/// Держит соединение с агентом и ленту. Если процесс агента завершился между
/// сообщениями, следующее сообщение поднимает сессию заново через продолжение —
/// пользователь этого не замечает.
@MainActor
@Observable
public final class ChatSession {

    public private(set) var timeline = ChatTimeline()

    /// Последние служебные строки для отладки. Пользователю не показываются.
    public private(set) var diagnostics: [String] = []

    @ObservationIgnored private let backend: any AgentBackend
    @ObservationIgnored private var connection: (any AgentConnection)?
    @ObservationIgnored private var pump: Task<Void, Never>?

    private static let diagnosticsLimit = 200

    public init(backend: any AgentBackend) {
        self.backend = backend
    }

    public var isBusy: Bool { timeline.isBusy }

    /// Отправляет сообщение. Пустые и повторные во время работы — игнорируются.
    public func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !timeline.isBusy else { return }

        timeline.appendUserMessage(trimmed)

        do {
            if connection == nil {
                let handle = try backend.connect(resuming: timeline.sessionID)
                connection = handle.connection
                consume(handle.stream)
            }
            try connection?.send(trimmed)
        } catch {
            connection?.stop()
            connection = nil
            timeline.recordLocalFailure(error.localizedDescription)
        }
    }

    /// Останавливает текущую работу агента.
    public func stop() {
        connection?.stop()
    }

    /// Начинает разговор с чистого листа: новая сессия, пустая лента.
    public func startOver() {
        pump?.cancel()
        pump = nil
        connection?.stop()
        connection = nil
        timeline = ChatTimeline()
        diagnostics.removeAll()
    }

    private func consume(_ stream: AsyncStream<AgentStreamItem>) {
        pump?.cancel()
        pump = Task { [weak self] in
            for await item in stream {
                guard let self else { return }
                self.handle(item)
            }
        }
    }

    private func handle(_ item: AgentStreamItem) {
        switch item {
        case .event(let event):
            timeline.apply(event)

        case .diagnostic(let line):
            diagnostics.append(line)
            if diagnostics.count > Self.diagnosticsLimit {
                diagnostics.removeFirst(diagnostics.count - Self.diagnosticsLimit)
            }

        case .ended(let exitCode, let stoppedByUser):
            timeline.markConnectionEnded(exitCode: exitCode, stoppedByUser: stoppedByUser)
            connection = nil
        }
    }
}
