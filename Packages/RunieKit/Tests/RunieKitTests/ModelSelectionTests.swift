import Foundation
import Testing
@testable import RunieKit

@MainActor
@Suite("Выбор модели")
struct ModelSelectionTests {

    /// Форма ответа снята с CLI 2.1.272 (`initialize`), лишние поля убраны.
    private static let initializeResponse = #"""
    {"type":"control_response","response":{"subtype":"success","request_id":"REQ","response":{"commands":[],"models":[
     {"value":"default","resolvedModel":"claude-opus-5[1m]","displayName":"Default (recommended)","description":"Opus 5 with 1M context · Best for everyday, complex tasks","supportsEffort":true},
     {"value":"sonnet","resolvedModel":"claude-sonnet-5","displayName":"Sonnet","description":"Sonnet 5 · Efficient for routine tasks"},
     {"value":"haiku","resolvedModel":"claude-haiku-4-5-20251001","displayName":"Haiku","description":"Haiku 4.5 · Fastest for quick answers"}
    ]}}}
    """#

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func response(requestID: String) throws -> AgentEvent {
        let raw = RawAgentEvent(payload: try JSONValue.decode(Data(
            Self.initializeResponse.replacingOccurrences(of: "REQ", with: requestID).utf8
        )))
        let events = AgentEventNormalizer().normalize(raw)
        return try #require(events.first)
    }

    @Test("ответ на initialize разбирается в список моделей")
    func parsesModels() throws {
        guard case .controlResponse(let response) = try response(requestID: "r1") else {
            Issue.record("не controlResponse"); return
        }
        #expect(response.requestID == "r1")
        #expect(response.isSuccess)
        let models = AgentModel.list(from: response.body)
        #expect(models.map(\.value) == ["default", "sonnet", "haiku"])
        #expect(models[1].resolvedModel == "claude-sonnet-5")
        #expect(models[2].description == "Haiku 4.5 · Fastest for quick answers")
    }

    @Test("управляющие запросы кодируются как в SDK")
    func encodesRequests() throws {
        let initialize = try JSONValue.decode(ControlRequest.initialize.ndjsonLine(requestID: "a"))
        #expect(initialize["type"]?.stringValue == "control_request")
        #expect(initialize["request_id"]?.stringValue == "a")
        #expect(initialize.path("request", "subtype")?.stringValue == "initialize")

        let setModel = try JSONValue.decode(ControlRequest.setModel("haiku").ndjsonLine(requestID: "b"))
        #expect(setModel.path("request", "subtype")?.stringValue == "set_model")
        #expect(setModel.path("request", "model")?.stringValue == "haiku")
    }

    @Test("подготовка поднимает агента, спрашивает модели и сохраняет список")
    func prepareFetchesModels() async throws {
        let backend = FakeBackend()
        let session = ChatSession(backend: backend)
        var updates: [[AgentModel]] = []
        session.onModelsUpdate = { updates.append($0) }

        session.prepare()
        let connection = try #require(backend.connections.first)
        #expect(connection.controls == [.initialize])
        #expect(connection.sent.isEmpty)

        connection.continuation.yield(.event(try response(requestID: connection.controlIDs[0])))
        #expect(await eventually { session.availableModels.count == 3 })
        #expect(updates.count == 1)

        // Повторная подготовка при живом соединении ничего не делает.
        session.prepare()
        #expect(backend.connections.count == 1)
    }

    @Test("выбор модели уходит в живую сессию и повторяется при новом подключении")
    func selectionAppliesNowAndLater() async throws {
        let backend = FakeBackend()
        let session = ChatSession(backend: backend)
        session.prepare()
        let first = try #require(backend.connections.first)

        session.selectModel("haiku")
        #expect(first.controls == [.initialize, .setModel("haiku")])

        first.stop()
        #expect(await eventually { !session.isBusy })
        // Дать сессии обработать конец соединения.
        try await Task.sleep(for: .milliseconds(50))
        session.send("привет")
        let second = try #require(backend.connections.last)
        #expect(backend.connections.count == 2)
        #expect(second.controls == [.initialize, .setModel("haiku")])

        session.selectModel(nil)
        #expect(second.controls.last == .setModel("default"))
    }

    @Test("кэш из прошлого запуска виден до ответа CLI")
    func restoresCache() {
        let session = ChatSession(backend: FakeBackend())
        let cached = [AgentModel(value: "sonnet", resolvedModel: nil, displayName: "Sonnet", description: "Sonnet 5")]
        session.restoreModels(cached, selected: "sonnet")
        #expect(session.availableModels == cached)
        #expect(session.selectedModel == "sonnet")
    }
}
