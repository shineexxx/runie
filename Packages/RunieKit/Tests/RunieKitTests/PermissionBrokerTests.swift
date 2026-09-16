import Foundation
import Testing
@testable import RunieKit

@Suite("Разрешения")
struct PermissionBrokerTests {

    private static func request(_ fixture: [AgentEvent]) throws -> PermissionRequest {
        try #require(fixture.compactMap {
            if case .permissionRequested(let request) = $0 { request } else { nil }
        }.first)
    }

    /// События фикстуры до вопроса о разрешении включительно.
    private static func eventsUntilRequest() throws -> [AgentEvent] {
        let events = try FixtureLoader.events("permission-request")
        let index = try #require(events.firstIndex { if case .permissionRequested = $0 { true } else { false } })
        return Array(events[...index])
    }

    @Test("вопрос CLI связан с вызовом инструмента и несёт его входные данные")
    func normalizesRequest() throws {
        let events = try FixtureLoader.events("permission-request")
        let request = try Self.request(events)
        let toolUse = try #require(events.compactMap { if case .toolUse(let use) = $0 { use } else { nil } }.first)

        #expect(request.toolName == "Bash")
        #expect(request.toolUseID == toolUse.id)
        #expect(request.input["command"]?.stringValue == "sw_vers")
        #expect(!request.requestID.isEmpty)
        #expect(!events.contains { if case .unknown = $0 { true } else { false } })
    }

    @Test("снятие вопроса CLI разбирается")
    func normalizesCancel() throws {
        let raw = RawAgentEvent(payload: try JSONValue.decode(Data(#"{"type":"control_cancel_request","request_id":"r1"}"#.utf8)))
        #expect(AgentEventNormalizer().normalize(raw) == [.permissionRequestCancelled(requestID: "r1")])
    }

    @Test("ответ — control_response с тем же request_id; разрешение возвращает вход инструмента")
    func encodesResponse() throws {
        let request = PermissionRequest(
            requestID: "r1", toolUseID: "t1", toolName: "Bash",
            input: .object(["command": .string("sw_vers")]), reason: nil
        )
        let allow = try JSONValue.decode(PermissionResponse(request: request, decision: .allow).ndjsonLine())
        #expect(allow["type"]?.stringValue == "control_response")
        #expect(allow.path("response", "subtype")?.stringValue == "success")
        #expect(allow.path("response", "request_id")?.stringValue == "r1")
        #expect(allow.path("response", "response", "behavior")?.stringValue == "allow")
        #expect(allow.path("response", "response", "updatedInput", "command")?.stringValue == "sw_vers")

        let deny = try JSONValue.decode(PermissionResponse(request: request, decision: .deny(message: "нет")).ndjsonLine())
        #expect(deny.path("response", "response", "behavior")?.stringValue == "deny")
        #expect(deny.path("response", "response", "message")?.stringValue == "нет")
    }

    @Test("лента: действие ждёт ответа, после отказа — отказано и вопрос снят")
    func timelineWaitsAndDenies() throws {
        var timeline = ChatTimeline()
        timeline.appendUserMessage("версия macOS")
        for event in try Self.eventsUntilRequest() { timeline.apply(event) }

        let request = try #require(timeline.pendingPermissions.first)
        let action = { timeline.items.compactMap { if case .action(let a) = $0 { a } else { nil } }.first }
        #expect(action()?.status == .awaitingApproval)
        #expect(timeline.isBusy)

        timeline.resolvePermission(request, allowed: false)
        #expect(timeline.pendingPermissions.isEmpty)
        #expect(action()?.status == .denied)

        // Остаток живого потока: результат с текстом отказа не перетирает «отказано».
        let rest = try FixtureLoader.events("permission-request").drop { if case .permissionRequested = $0 { false } else { true } }.dropFirst()
        for event in rest { timeline.apply(event) }
        #expect(action()?.status == .denied)
        #expect(!timeline.isBusy)
    }

    @Test("лента: конец хода снимает неотвеченные вопросы")
    func turnEndClearsPending() throws {
        var timeline = ChatTimeline()
        timeline.appendUserMessage("версия macOS")
        for event in try Self.eventsUntilRequest() { timeline.apply(event) }
        timeline.markConnectionEnded(exitCode: 15, stoppedByUser: true)
        #expect(timeline.pendingPermissions.isEmpty)
    }
}

@MainActor
@Suite("Разрешения в сессии")
struct PermissionSessionTests {

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func start(_ session: ChatSession, _ backend: FakeBackend) throws -> FakeBackend.Connection {
        session.send("версия macOS")
        let connection = try #require(backend.connections.last)
        let events = try FixtureLoader.events("permission-request")
        let index = try #require(events.firstIndex { if case .permissionRequested = $0 { true } else { false } })
        for event in events[...index] { connection.continuation.yield(.event(event)) }
        return connection
    }

    @Test("вопрос доходит до сессии, ответ уходит агенту")
    func answerReachesAgent() async throws {
        let backend = FakeBackend()
        let session = ChatSession(backend: backend)
        var asked = 0
        session.onPermissionRequest = { asked += 1 }

        let connection = try start(session, backend)
        #expect(await eventually { session.pendingPermission != nil })
        #expect(asked == 1)

        let request = try #require(session.pendingPermission)
        session.answer(request, allow: true)
        #expect(session.pendingPermission == nil)
        #expect(connection.responses.count == 1)
        #expect(connection.responses.first?.1 == .allow)
    }

    @Test("«всегда» — такой же запрос в этом разговоре разрешается без вопроса")
    func standingGrantAutoAllows() async throws {
        let backend = FakeBackend()
        let session = ChatSession(backend: backend)
        let connection = try start(session, backend)
        #expect(await eventually { session.pendingPermission != nil })
        session.answer(try #require(session.pendingPermission), allow: true, remember: true)

        var asked = 0
        session.onPermissionRequest = { asked += 1 }
        let again = PermissionRequest(
            requestID: "r2", toolUseID: nil, toolName: "Bash",
            input: .object(["command": .string("sw_vers")]), reason: nil
        )
        connection.continuation.yield(.event(.permissionRequested(again)))
        #expect(await eventually { connection.responses.count == 2 })
        #expect(asked == 0)
        #expect(session.pendingPermission == nil)

        // Другая команда — снова вопрос.
        let other = PermissionRequest(
            requestID: "r3", toolUseID: nil, toolName: "Bash",
            input: .object(["command": .string("rm -rf ~/x")]), reason: nil
        )
        connection.continuation.yield(.event(.permissionRequested(other)))
        #expect(await eventually { session.pendingPermission?.requestID == "r3" })
        #expect(asked == 1)
    }
}
