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

    /// Какой разговор сейчас в чате.
    public private(set) var conversationID = UUID()
    @ObservationIgnored private var conversationCreatedAt = Date()
    /// Растёт при каждом сохранении — список истории по нему обновляется.
    public private(set) var historyRevision = 0
    /// Куда сохранять разговоры. `nil` — не сохранять.
    @ObservationIgnored public var store: ChatHistoryStore?

    /// Последние служебные строки для отладки. Пользователю не показываются.
    public private(set) var diagnostics: [String] = []

    @ObservationIgnored private let backend: any AgentBackend
    @ObservationIgnored private var connection: (any AgentConnection)?
    @ObservationIgnored private var pump: Task<Void, Never>?
    /// Что человек разрешил «всегда» в этом разговоре. Такие запросы не показываются.
    @ObservationIgnored private var standingGrants: Set<String> = []

    // MARK: Модель

    /// Модели, которые предлагает Claude Code. Пусто, пока CLI не ответил и кэша нет.
    public private(set) var availableModels: [AgentModel] = []
    /// Выбранная модель (`value`). `nil` — как настроено в самом Claude Code.
    public private(set) var selectedModel: String?
    /// Список моделей обновился — приложение кэширует его.
    @ObservationIgnored public var onModelsUpdate: (([AgentModel]) -> Void)?
    @ObservationIgnored private var initializeRequestID: String?

    /// Правила из настроек: какие группы действий разрешать без вопроса.
    @ObservationIgnored public var policy = PermissionPolicy()

    /// Агент ждёт разрешения. Приложение, например, открывает чат, если он закрыт.
    @ObservationIgnored public var onPermissionRequest: (() -> Void)?

    private static let diagnosticsLimit = 200

    public init(backend: any AgentBackend) {
        self.backend = backend
    }

    public var isBusy: Bool { timeline.isBusy }

    /// Модели и выбор из прошлого запуска — чтобы меню было видно сразу, до ответа CLI.
    public func restoreModels(_ models: [AgentModel], selected: String?) {
        availableModels = models
        selectedModel = selected
    }

    /// Выбирает модель. Живой сессии она передаётся сразу, новой — при подключении.
    public func selectModel(_ value: String?) {
        selectedModel = value
        guard let connection else { return }
        do {
            try connection.send(.setModel(value ?? "default"), requestID: UUID().uuidString)
        } catch {
            diagnostics.append("set_model: \(error.localizedDescription)")
        }
    }

    /// Поднимает агента заранее, не отправляя сообщения: так к открытию чата уже
    /// известен свежий список моделей, а первый ответ приходит быстрее.
    public func prepare() {
        guard connection == nil else { return }
        do {
            try connect()
        } catch {
            diagnostics.append("prepare: \(error.localizedDescription)")
        }
    }

    private func connect() throws {
        let handle = try backend.connect(resuming: timeline.sessionID)
        connection = handle.connection
        consume(handle.stream)
        let requestID = UUID().uuidString
        initializeRequestID = requestID
        try handle.connection.send(.initialize, requestID: requestID)
        if let selectedModel {
            try handle.connection.send(.setModel(selectedModel), requestID: UUID().uuidString)
        }
    }

    /// Вопрос о разрешении, который показывать сейчас.
    public var pendingPermission: PermissionRequest? { timeline.pendingPermissions.first }

    /// Отвечает на вопрос о разрешении. `remember` — больше не спрашивать о таком
    /// же действии до конца разговора.
    public func answer(_ request: PermissionRequest, allow: Bool, remember: Bool = false) {
        guard timeline.pendingPermissions.contains(request) else { return }
        if allow, remember {
            standingGrants.insert(PermissionGrant.key(for: request))
        }
        timeline.resolvePermission(request, allowed: allow)
        do {
            try connection?.respond(
                to: request,
                with: allow ? .allow : .deny(message: "Пользователь не разрешил это действие.")
            )
        } catch {
            diagnostics.append("permission response: \(error.localizedDescription)")
        }
    }

    /// Отправляет сообщение. Пустые и повторные во время работы — игнорируются.
    ///
    /// Контекст уходит агенту перед сообщением, но в ленте его нет: человек видит
    /// только то, что написал сам.
    public func send(_ text: String, context: AppContext? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !timeline.isBusy else { return }

        timeline.appendUserMessage(trimmed)
        persist()

        do {
            if connection == nil {
                try connect()
            }
            try connection?.send(context?.decorate(trimmed) ?? trimmed)
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
        standingGrants.removeAll()
        conversationID = UUID()
        conversationCreatedAt = Date()
    }

    /// Открывает сохранённый разговор: следующее сообщение продолжит его сессию.
    public func open(_ record: ConversationRecord) {
        startOver()
        timeline = ChatTimeline(restoring: record.items, sessionID: record.sessionID)
        conversationID = record.id
        conversationCreatedAt = record.createdAt
    }

    /// Сохраняет разговор, если в нём что-то есть.
    private func persist() {
        guard let store, !timeline.items.isEmpty else { return }
        let record = ConversationRecord(
            id: conversationID,
            sessionID: timeline.sessionID,
            title: ConversationRecord.title(for: timeline.items),
            createdAt: conversationCreatedAt,
            updatedAt: Date(),
            items: timeline.items
        )
        do {
            try store.save(record)
            historyRevision += 1
        } catch {
            diagnostics.append("history: \(error.localizedDescription)")
        }
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
            switch event {
            case .turnCompleted, .turnFailed, .sessionStarted: persist()
            default: break
            }
            if case .controlResponse(let response) = event,
               response.requestID == initializeRequestID, response.isSuccess {
                initializeRequestID = nil
                let models = AgentModel.list(from: response.body)
                if !models.isEmpty, models != availableModels {
                    availableModels = models
                    onModelsUpdate?(models)
                }
            }
            if case .permissionRequested(let request) = event {
                if policy.allows(request) || standingGrants.contains(PermissionGrant.key(for: request)) {
                    answer(request, allow: true)
                } else {
                    onPermissionRequest?()
                }
            }

        case .diagnostic(let line):
            diagnostics.append(line)
            if diagnostics.count > Self.diagnosticsLimit {
                diagnostics.removeFirst(diagnostics.count - Self.diagnosticsLimit)
            }

        case .ended(let exitCode, let stoppedByUser):
            timeline.markConnectionEnded(exitCode: exitCode, stoppedByUser: stoppedByUser)
            connection = nil
            persist()
        }
    }
}
