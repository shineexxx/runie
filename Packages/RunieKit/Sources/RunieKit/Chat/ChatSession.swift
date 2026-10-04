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

    @ObservationIgnored private var backend: any AgentBackend
    @ObservationIgnored private var connection: (any AgentConnection)?
    @ObservationIgnored private var pump: Task<Void, Never>?
    /// Что человек разрешил «всегда» в этом разговоре. Такие запросы не показываются.
    @ObservationIgnored private var standingGrants: Set<String> = []
    /// Разрешения изменились изнутри разговора — приложению нужно их сохранить.
    @ObservationIgnored public var onPolicyUpdate: ((PermissionPolicy) -> Void)?

    // MARK: Разговоры в фоне

    /// Разговор, который продолжает работать, пока человек открыл другой.
    /// Свой процесс агента, своя лента — ход доводится до конца и сохраняется.
    @MainActor
    private final class BackgroundRun {
        let conversationID: UUID
        let createdAt: Date
        var timeline: ChatTimeline
        let connection: any AgentConnection
        let pump: Task<Void, Never>?
        let standingGrants: Set<String>

        init(conversationID: UUID, createdAt: Date, timeline: ChatTimeline,
             connection: any AgentConnection, pump: Task<Void, Never>?, standingGrants: Set<String>) {
            self.conversationID = conversationID
            self.createdAt = createdAt
            self.timeline = timeline
            self.connection = connection
            self.pump = pump
            self.standingGrants = standingGrants
        }
    }

    @ObservationIgnored private var backgroundRuns: [UUID: BackgroundRun] = [:]
    /// Какие разговоры сейчас работают в фоне — для значка в списке.
    public private(set) var runningInBackground: Set<UUID> = []
    /// В фоновом разговоре Руни ждёт разрешения — человеку надо туда вернуться.
    @ObservationIgnored public var onBackgroundAttention: ((UUID) -> Void)?
    /// Фоновый разговор закончил ход: номер, название, начало ответа, неудача ли.
    @ObservationIgnored public var onBackgroundFinished: ((BackgroundResult) -> Void)?

    /// Чем закончился разговор, доработавший в фоне.
    public struct BackgroundResult: Sendable {
        public let conversationID: UUID
        public let title: String
        public let reply: String?
        public let failed: Bool
    }

    // MARK: Модель

    /// Модели, которые предлагает Claude Code. Пусто, пока CLI не ответил и кэша нет.
    public private(set) var availableModels: [AgentModel] = []
    /// Выбранная модель (`value`). `nil` — как настроено в самом Claude Code.
    public private(set) var selectedModel: String?
    /// Список моделей обновился — приложение кэширует его.
    @ObservationIgnored public var onModelsUpdate: (([AgentModel]) -> Void)?
    @ObservationIgnored private var initializeRequestID: String?

    // MARK: Расширения

    /// MCP-серверы по последнему `mcp_status`.
    public private(set) var mcpServers: [MCPServerInfo] = []
    /// Навыки и плагины из начала последней сессии.
    public private(set) var skills: [String] = []
    public private(set) var plugins: [PluginInfo] = []
    /// Навыки с описаниями из ответа на `initialize` — известны сразу после подключения.
    public private(set) var skillInfos: [SkillInfo] = []
    /// Навыки, выключенные в Runie. Применяются при следующем подключении.
    @ObservationIgnored public var disabledSkills: Set<String> = []
    /// MCP-серверы, выключенные в Runie. Настройки Claude Code не трогаются: при
    /// подключении инструменты сервера просто запрещаются.
    @ObservationIgnored public var disabledMCPServers: Set<String> = []
    @ObservationIgnored private var mcpStatusRequestID: String?

    /// Встроенные инструменты приложения (MCP-сервер в процессе Runie).
    @ObservationIgnored public var hostTools: HostToolServer?

    /// Правила из настроек: какие группы действий разрешать без вопроса.
    @ObservationIgnored public var policy = PermissionPolicy()

    /// Превращает сообщение перед отправкой агенту — например, `/отчёт` в вызов команды.
    /// В ленте остаётся то, что человек написал.
    @ObservationIgnored public var expandMessage: ((String) -> String?)?

    /// Агент ждёт разрешения. Приложение, например, открывает чат, если он закрыт.
    @ObservationIgnored public var onPermissionRequest: (() -> Void)?

    private static let diagnosticsLimit = 200

    public init(backend: any AgentBackend) {
        self.backend = backend
    }

    public var isBusy: Bool { timeline.isBusy }

    /// Подменяет бэкенд — например, когда Claude Code установили уже после запуска.
    /// Текущее соединение закрывается: следующее сообщение поднимет новое.
    public func replaceBackend(_ newBackend: any AgentBackend) {
        guard !isBusy else { return }
        pump?.cancel()
        pump = nil
        connection?.stop()
        connection = nil
        backend = newBackend
    }

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

    /// Запрашивает состояние MCP-серверов; поднимает агента, если его нет.
    public func refreshExtensions() {
        do {
            if connection == nil { try connect() }
            let requestID = UUID().uuidString
            mcpStatusRequestID = requestID
            try connection?.send(.mcpStatus, requestID: requestID)
        } catch {
            diagnostics.append("mcp_status: \(error.localizedDescription)")
        }
    }

    /// Переподключает агента, когда он свободен: так подхватываются новые серверы и
    /// выключенные навыки. Разговор продолжается той же сессией.
    public func reloadAgent() {
        guard !isBusy, let current = connection else { return }
        connection = nil
        pump?.cancel()
        pump = nil
        current.stop()
        prepare()
    }

    /// Подключиться заново, как только Руни освободится: появился новый сервер или
    /// навык, а текущий процесс Claude Code о нём не знает.
    public func reloadWhenIdle() {
        if isBusy {
            reloadPending = true
        } else {
            reloadAgent()
        }
    }

    @ObservationIgnored private var reloadPending = false

    private func reloadIfPending() {
        guard reloadPending, !isBusy else { return }
        reloadPending = false
        // Не из обработки события: перезапуск отменяет тот самый поток, что её ведёт.
        Task { @MainActor in self.reloadAgent() }
    }

    private func connect() throws {
        let handle = try makeConnection(resuming: timeline.sessionID)
        connection = handle.connection
        consume(handle.stream, conversation: conversationID)
    }

    /// Поднимает процесс агента с нашими настройками: навыки, серверы, модель.
    private func makeConnection(resuming sessionID: String?) throws -> AgentConnectionHandle {
        let rules = disabledSkills.sorted().map { "Skill(\($0))" }
            + disabledMCPServers.sorted().map(MCPServerInfo.denyRule(forServer:))
        let handle = try backend.connect(resuming: sessionID, disallowedTools: rules)
        let requestID = UUID().uuidString
        initializeRequestID = requestID
        if let hostTools {
            try handle.connection.send(.initializeWithHostServers([hostTools.name]), requestID: requestID)
        } else {
            try handle.connection.send(.initialize, requestID: requestID)
        }
        if let selectedModel {
            try handle.connection.send(.setModel(selectedModel), requestID: UUID().uuidString)
        }
        return handle
    }

    /// Быстрый запрос: новый разговор, который сразу работает в фоне. Человек
    /// остаётся там, где был; ответ сохранится в историю. Возвращает номер разговора.
    @discardableResult
    public func sendInBackground(_ text: String) -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let id = UUID()
        let createdAt = Date()
        var timeline = ChatTimeline()
        timeline.appendUserMessage(trimmed, attachments: [])
        do {
            let handle = try makeConnection(resuming: nil)
            let stream = handle.stream
            let pump = Task { [weak self] in
                for await item in stream {
                    guard let self else { return }
                    self.route(item, conversation: id)
                }
            }
            let run = BackgroundRun(
                conversationID: id, createdAt: createdAt, timeline: timeline,
                connection: handle.connection, pump: pump, standingGrants: []
            )
            backgroundRuns[id] = run
            runningInBackground.insert(id)
            persist(timeline, id: id, createdAt: createdAt)
            try handle.connection.send(UserMessage(expandMessage?(trimmed) ?? trimmed))
            return id
        } catch {
            if let run = backgroundRuns[id] { finish(run) }
            diagnostics.append("background: \(error.localizedDescription)")
            return nil
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
            // Вход под учётной записью запоминается насовсем и по сайтам: человек
            // разрешает его один раз для дневника, а не для всего интернета.
            if PermissionClassifier.categories(for: request).contains(.signInAsYou),
               let site = PermissionClassifier.site(of: request) {
                policy.signedInSites.insert(site)
                onPolicyUpdate?(policy)
            }
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
    public func send(_ text: String, context: AppContext? = nil, attachments: [Attachment] = []) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty, !timeline.isBusy else { return }
        if trimmed.isEmpty {
            trimmed = attachments.allSatisfy(\.isImage) ? "Посмотри на это." : "Посмотри эти файлы."
        }

        timeline.appendUserMessage(trimmed, attachments: attachments)
        persist()

        do {
            if connection == nil {
                try connect()
            }
            // Картинки модель видит сама; путь к ним и к остальным файлам — в тексте,
            // чтобы агент мог с ними работать: переслать, переложить, прочитать.
            let request = expandMessage?(trimmed) ?? trimmed
            let body = (context?.decorate(request) ?? request) + Attachment.agentNote(for: attachments)
            let images = attachments.filter(\.isImage).compactMap { try? MessageImage.load(from: $0.url) }
            try connection?.send(UserMessage(body, images: images))
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
        // Руни занят — разговор доработает в фоне, а не оборвётся.
        if !sendToBackgroundIfBusy() {
            pump?.cancel()
            pump = nil
            connection?.stop()
            connection = nil
        }
        timeline = ChatTimeline()
        diagnostics.removeAll()
        standingGrants.removeAll()
        conversationID = UUID()
        conversationCreatedAt = Date()
    }

    /// Открывает сохранённый разговор: следующее сообщение продолжит его сессию.
    public func open(_ record: ConversationRecord) {
        guard record.id != conversationID else { return }
        startOver()
        // Этот разговор ещё работает в фоне — возвращаем его живым, а не из файла.
        if let run = backgroundRuns[record.id] {
            bringBack(run)
            return
        }
        timeline = ChatTimeline(restoring: record.items, sessionID: record.sessionID)
        conversationID = record.id
        conversationCreatedAt = record.createdAt
    }

    /// Сохраняет разговор, если в нём что-то есть.
    private func persist() {
        persist(timeline, id: conversationID, createdAt: conversationCreatedAt)
    }

    private func persist(_ timeline: ChatTimeline, id: UUID, createdAt: Date) {
        guard let store, !timeline.items.isEmpty else { return }
        let record = ConversationRecord(
            id: id,
            sessionID: timeline.sessionID,
            title: ConversationRecord.title(for: timeline.items),
            createdAt: createdAt,
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

    /// Читает события агента. Каждое уходит в свой разговор: если человек уже
    /// открыл другой, этот доработает в фоне.
    private func consume(_ stream: AsyncStream<AgentStreamItem>, conversation: UUID) {
        pump?.cancel()
        pump = Task { [weak self] in
            for await item in stream {
                guard let self else { return }
                self.route(item, conversation: conversation)
            }
        }
    }

    private func route(_ item: AgentStreamItem, conversation: UUID) {
        if let run = backgroundRuns[conversation] {
            handleInBackground(item, run: run)
        } else if conversation == conversationID {
            handle(item)
        }
        // Иначе это хвост разговора, который уже закрыли, — его не показываем.
    }

    /// Отправляет текущий разговор работать в фон, если Руни сейчас занят им.
    private func sendToBackgroundIfBusy() -> Bool {
        guard isBusy, let connection else { return false }
        let run = BackgroundRun(
            conversationID: conversationID, createdAt: conversationCreatedAt, timeline: timeline,
            connection: connection, pump: pump, standingGrants: standingGrants
        )
        backgroundRuns[conversationID] = run
        runningInBackground.insert(conversationID)
        // Процесс и его поток событий теперь принадлежат фоновому разговору.
        self.connection = nil
        pump = nil
        return true
    }

    /// Фоновый разговор снова на экране: та же лента, тот же живой процесс.
    private func bringBack(_ run: BackgroundRun) {
        backgroundRuns[run.conversationID] = nil
        runningInBackground.remove(run.conversationID)
        timeline = run.timeline
        connection = run.connection
        pump = run.pump
        standingGrants = run.standingGrants
        conversationID = run.conversationID
        conversationCreatedAt = run.createdAt
    }

    private func handleInBackground(_ item: AgentStreamItem, run: BackgroundRun) {
        switch item {
        case .event(let event):
            run.timeline.apply(event)
            if case .mcpMessage(let message) = event, let hostTools, message.serverName == hostTools.name {
                let connection = run.connection
                Task {
                    let response = await hostTools.handle(message.message)
                    try? connection.respondToMCP(MCPReply(requestID: message.requestID, response: response))
                }
            }
            if case .permissionRequested(let request) = event {
                if policy.allows(request) || run.standingGrants.contains(PermissionGrant.key(for: request)) {
                    run.timeline.resolvePermission(request, allowed: true)
                    try? run.connection.respond(to: request, with: .allow)
                } else {
                    // Вопрос ждёт, пока человек вернётся в этот разговор.
                    onBackgroundAttention?(run.conversationID)
                }
            }
            switch event {
            case .turnCompleted, .turnFailed:
                persist(run.timeline, id: run.conversationID, createdAt: run.createdAt)
                finish(run)
                let turn = ChatTurn.split(run.timeline.items).last
                onBackgroundFinished?(BackgroundResult(
                    conversationID: run.conversationID,
                    title: ConversationRecord.title(for: run.timeline.items),
                    reply: turn?.reply,
                    failed: turn?.failure != nil
                ))
            case .sessionStarted:
                persist(run.timeline, id: run.conversationID, createdAt: run.createdAt)
            default:
                break
            }
        case .diagnostic:
            break
        case .ended(let exitCode, let stoppedByUser):
            run.timeline.markConnectionEnded(exitCode: exitCode, stoppedByUser: stoppedByUser)
            persist(run.timeline, id: run.conversationID, createdAt: run.createdAt)
            finish(run)
        }
    }

    /// Фоновый ход закончился: процесс больше не нужен, следующее сообщение в этом
    /// разговоре поднимет его заново с продолжением сессии.
    private func finish(_ run: BackgroundRun) {
        backgroundRuns[run.conversationID] = nil
        runningInBackground.remove(run.conversationID)
        run.pump?.cancel()
        run.connection.stop()
    }

    /// Останавливает всё: и разговор на экране, и фоновые. Для выхода из приложения.
    public func stopAll() {
        stop()
        for run in backgroundRuns.values {
            persist(run.timeline, id: run.conversationID, createdAt: run.createdAt)
            run.connection.stop()
        }
        backgroundRuns.removeAll()
        runningInBackground.removeAll()
    }

    private func handle(_ item: AgentStreamItem) {
        switch item {
        case .event(let event):
            timeline.apply(event)
            switch event {
            case .turnCompleted, .turnFailed:
                persist()
                reloadIfPending()
            case .sessionStarted: persist()
            default: break
            }
            if case .sessionStarted(let info) = event {
                if !info.skills.isEmpty { skills = info.skills }
                plugins = info.plugins
            }
            if case .controlResponse(let response) = event, response.requestID == mcpStatusRequestID {
                mcpStatusRequestID = nil
                if response.isSuccess { mcpServers = MCPServerInfo.list(from: response.body) }
            }
            if case .controlResponse(let response) = event,
               response.requestID == initializeRequestID, response.isSuccess {
                initializeRequestID = nil
                let foundSkills = SkillInfo.fromCommands(response.body)
                if !foundSkills.isEmpty { skillInfos = foundSkills }
                let models = AgentModel.list(from: response.body)
                if !models.isEmpty, models != availableModels {
                    availableModels = models
                    onModelsUpdate?(models)
                }
            }
            if case .mcpMessage(let message) = event, let hostTools, message.serverName == hostTools.name,
               let connection {
                // Инструмент может работать долго — не держим поток событий.
                Task {
                    let response = await hostTools.handle(message.message)
                    do {
                        try connection.respondToMCP(MCPReply(requestID: message.requestID, response: response))
                    } catch {
                        self.diagnostics.append("mcp reply: \(error.localizedDescription)")
                    }
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
            // Соединения нет — следующее и так поднимется с новыми серверами.
            reloadPending = false
        }
    }
}
