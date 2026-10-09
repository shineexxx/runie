import Foundation
import Testing
@testable import RunieKit

/// Поддельный бэкенд: отдаёт заранее заданные события и запоминает, что ему отправили.
final class FakeBackend: AgentBackend, @unchecked Sendable {

    final class Connection: AgentConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [String] = []
        private var _responses: [(PermissionRequest, PermissionDecision)] = []
        private(set) var stopped = false
        let continuation: AsyncStream<AgentStreamItem>.Continuation

        init(continuation: AsyncStream<AgentStreamItem>.Continuation) {
            self.continuation = continuation
        }

        var sent: [String] { lock.withLock { _sent } }
        var responses: [(PermissionRequest, PermissionDecision)] { lock.withLock { _responses } }

        private var _controls: [ControlRequest] = []
        var controls: [ControlRequest] { lock.withLock { _controls } }
        private var _controlIDs: [String] = []
        var controlIDs: [String] { lock.withLock { _controlIDs } }

        private var _mcpReplies: [MCPReply] = []
        var mcpReplies: [MCPReply] { lock.withLock { _mcpReplies } }

        func respondToMCP(_ reply: MCPReply) throws {
            lock.withLock { _mcpReplies.append(reply) }
        }

        func send(_ request: ControlRequest, requestID: String) throws {
            lock.withLock {
                _controls.append(request)
                _controlIDs.append(requestID)
            }
        }

        func respond(to request: PermissionRequest, with decision: PermissionDecision) throws {
            lock.withLock { _responses.append((request, decision)) }
        }

        private var _messages: [UserMessage] = []
        var messages: [UserMessage] { lock.withLock { _messages } }

        func send(_ message: UserMessage) throws {
            lock.withLock {
                _sent.append(message.text)
                _messages.append(message)
            }
        }

        func stop() {
            lock.withLock { stopped = true }
            continuation.yield(.ended(exitCode: 15, stoppedByUser: true))
            continuation.finish()
        }
    }

    private let lock = NSLock()
    private var _connections: [Connection] = []
    private var _resumedWith: [String?] = []
    var failNextConnect = false

    var connections: [Connection] { lock.withLock { _connections } }
    var resumedWith: [String?] { lock.withLock { _resumedWith } }

    private var _disallowed: [[String]] = []
    var disallowed: [[String]] { lock.withLock { _disallowed } }

    func connect(resuming sessionID: String?, disallowedTools: [String]) throws -> AgentConnectionHandle {
        lock.withLock { _disallowed.append(disallowedTools) }
        if failNextConnect {
            failNextConnect = false
            throw AgentRuntime.Failure.launchFailed("нет claude")
        }
        let (stream, continuation) = AsyncStream<AgentStreamItem>.makeStream()
        let connection = Connection(continuation: continuation)
        lock.withLock {
            _connections.append(connection)
            _resumedWith.append(sessionID)
        }
        return AgentConnectionHandle(connection: connection, stream: stream)
    }
}

@MainActor
@Suite("ChatSession")
struct ChatSessionTests {

    /// Ждёт, пока условие станет истинным: события доходят через асинхронную задачу.
    private func eventually(
        _ condition: @MainActor () -> Bool,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test("первое сообщение поднимает новую сессию и уходит агенту")
    func firstMessageConnects() async {
        let backend = FakeBackend()
        let session = ChatSession(backend: backend)

        session.send("  привет  ")

        #expect(backend.connections.count == 1)
        #expect(backend.resumedWith == [nil])
        #expect(backend.connections.first?.sent == ["привет"])
        #expect(session.isBusy)
    }

    @Test("события агента попадают в ленту")
    func eventsReachTimeline() async throws {
        let backend = FakeBackend()
        let session = ChatSession(backend: backend)
        session.send("прочитай todo")

        let connection = try #require(backend.connections.first)
        for event in try FixtureLoader.events("tool-use") {
            connection.continuation.yield(.event(event))
        }

        #expect(await eventually { !session.isBusy })
        #expect(session.timeline.items.contains { if case .action = $0 { true } else { false } })
        #expect(session.timeline.sessionID != nil)
    }

    @Test("пустое сообщение и сообщение во время работы игнорируются")
    func ignoresEmptyAndBusy() {
        let backend = FakeBackend()
        let session = ChatSession(backend: backend)

        session.send("   ")
        #expect(backend.connections.isEmpty)

        session.send("первое")
        session.send("второе, пока агент занят")
        #expect(backend.connections.first?.sent == ["первое"])
    }

    @Test("после смерти процесса следующее сообщение продолжает ту же сессию")
    func reconnectsWithResume() async throws {
        let backend = FakeBackend()
        let session = ChatSession(backend: backend)
        session.send("раз")

        let first = try #require(backend.connections.first)
        for event in try FixtureLoader.events("tool-use") {
            first.continuation.yield(.event(event))
        }
        first.continuation.yield(.ended(exitCode: 0, stoppedByUser: false))
        first.continuation.finish()

        #expect(await eventually { !session.isBusy })

        session.send("два")
        #expect(backend.connections.count == 2)
        #expect(backend.resumedWith == [nil, "11111111-1111-4111-8111-111111111111"])
        #expect(backend.connections.last?.sent == ["два"])
    }

    @Test("пока процесс жив, новое соединение не поднимается")
    func reusesLiveConnection() async throws {
        let backend = FakeBackend()
        let session = ChatSession(backend: backend)
        session.send("раз")

        let connection = try #require(backend.connections.first)
        connection.continuation.yield(.event(.turnCompleted(TurnSummary(
            result: nil, durationMilliseconds: nil, costUSD: nil, turnCount: nil, permissionDenialCount: 0
        ))))
        #expect(await eventually { !session.isBusy })

        session.send("два")
        #expect(backend.connections.count == 1)
        #expect(connection.sent == ["раз", "два"])
    }

    @Test("ошибка подключения видна в ленте и не блокирует следующую попытку")
    func connectFailureIsRecoverable() {
        let backend = FakeBackend()
        backend.failNextConnect = true
        let session = ChatSession(backend: backend)

        session.send("раз")
        #expect(!session.isBusy)
        #expect(session.timeline.items.contains {
            if case .notice(let notice) = $0 { notice.kind == .error } else { false }
        })

        session.send("два")
        #expect(backend.connections.count == 1)
    }

    @Test("остановка прерывает работу с пометкой «Остановлено»")
    func stopInterrupts() async throws {
        let backend = FakeBackend()
        let session = ChatSession(backend: backend)
        session.send("долгая задача")

        session.stop()

        #expect(await eventually { !session.isBusy })
        #expect(backend.connections.first?.stopped == true)
        #expect(session.timeline.items.contains {
            if case .notice(let notice) = $0 { notice.text == t("Остановлено") } else { false }
        })
    }

    @Test("начать заново: пустая лента и новая сессия без продолжения")
    func startOverClearsEverything() async throws {
        let backend = FakeBackend()
        let session = ChatSession(backend: backend)
        session.send("раз")
        let first = try #require(backend.connections.first)
        for event in try FixtureLoader.events("tool-use") {
            first.continuation.yield(.event(event))
        }
        #expect(await eventually { !session.isBusy })

        session.startOver()
        #expect(session.timeline.items.isEmpty)
        #expect(session.timeline.sessionID == nil)

        session.send("с чистого листа")
        #expect(backend.resumedWith.last == .some(nil))
    }

    private func temporaryStore() -> ChatHistoryStore {
        ChatHistoryStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("runie-bg-\(UUID().uuidString)"))
    }

    @Test("занятый разговор при переходе в другой дорабатывает в фоне и сохраняется")
    func busyConversationFinishesInBackground() async throws {
        let backend = FakeBackend()
        let session = ChatSession(backend: backend)
        session.store = temporaryStore()
        session.send("долгая задача")
        let first = try #require(backend.connections.first)
        let busyID = session.conversationID

        session.startOver()
        #expect(session.runningInBackground == [busyID])
        #expect(!first.stopped)
        #expect(!session.isBusy)
        #expect(session.timeline.items.isEmpty)

        for event in try FixtureLoader.events("tool-use") {
            first.continuation.yield(.event(event))
        }
        #expect(await eventually { session.runningInBackground.isEmpty })
        // Ход дописан в историю, а на экране по-прежнему новый разговор.
        let saved = try #require(session.store?.list().first { $0.id == busyID })
        #expect(saved.items.contains { if case .action = $0 { true } else { false } })
        #expect(session.timeline.items.isEmpty)
    }

    @Test("вернуться в фоновый разговор — тот же живой процесс, а не новый")
    func reopeningBackgroundConversationReattaches() async throws {
        let backend = FakeBackend()
        let session = ChatSession(backend: backend)
        session.store = temporaryStore()
        session.send("долгая задача")
        let first = try #require(backend.connections.first)
        let busyID = session.conversationID

        session.startOver()
        let record = try #require(session.store?.list().first { $0.id == busyID })
        session.open(record)

        #expect(session.conversationID == busyID)
        #expect(session.runningInBackground.isEmpty)
        #expect(session.isBusy)
        #expect(backend.connections.count == 1)

        for event in try FixtureLoader.events("tool-use") {
            first.continuation.yield(.event(event))
        }
        #expect(await eventually { !session.isBusy })
    }

    @Test("быстрый запрос создаёт фоновый разговор и не трогает открытый")
    func quickRequestRunsInBackground() async throws {
        let backend = FakeBackend()
        let session = ChatSession(backend: backend)
        session.store = temporaryStore()
        let openID = session.conversationID
        var finished: [ChatSession.BackgroundResult] = []
        session.onBackgroundFinished = { finished.append($0) }

        let id = try #require(session.sendInBackground("сколько дней до нового года"))
        #expect(session.conversationID == openID)
        #expect(session.timeline.items.isEmpty)
        #expect(session.runningInBackground == [id])
        let connection = try #require(backend.connections.first)
        #expect(connection.sent == ["сколько дней до нового года"])

        for event in try FixtureLoader.events("tool-use") {
            connection.continuation.yield(.event(event))
        }
        #expect(await eventually { !finished.isEmpty })
        #expect(finished.first?.conversationID == id)
        #expect(session.runningInBackground.isEmpty)
        #expect(session.store?.list().contains { $0.id == id } == true)
    }

    @Test("после хода известно, сколько контекста занято")
    func contextUsageAfterTurn() async throws {
        let backend = FakeBackend()
        let session = ChatSession(backend: backend)
        session.send("прочитай todo")
        let connection = try #require(backend.connections.first)
        for event in try FixtureLoader.events("tool-use") {
            connection.continuation.yield(.event(event))
        }
        #expect(await eventually { !session.isBusy })
        let context = try #require(session.timeline.context)
        #expect(context.window == 1_000_000)
        #expect(context.used > 0 && context.used < context.window)
    }

    @Test("сжатие: в ленте пометка, агенту уходит /compact")
    func compactSendsCommandQuietly() async throws {
        let backend = FakeBackend()
        let session = ChatSession(backend: backend)
        session.send("прочитай todo")
        let connection = try #require(backend.connections.first)
        for event in try FixtureLoader.events("tool-use") {
            connection.continuation.yield(.event(event))
        }
        #expect(await eventually { !session.isBusy })

        session.compact()
        #expect(session.isBusy)
        #expect(connection.sent.last == "/compact")
        #expect(!session.timeline.items.contains { if case .user(let item) = $0 { item.text == "/compact" } else { false } })
    }
}
