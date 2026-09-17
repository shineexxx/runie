import Foundation
import Testing
@testable import RunieKit

@Suite("Источники подсказок из MCP")
struct MCPSourcesTests {

    @Test("только читающие инструменты своего сервера")
    func readOnlyPolicy() {
        let server = "claude.ai Slack"
        #expect(ReadOnlyTools.allows(toolName: "mcp__claude_ai_Slack__slack_search_messages", server: server))
        #expect(ReadOnlyTools.allows(toolName: "mcp__claude_ai_Slack__slack_read_channel", server: server))
        #expect(!ReadOnlyTools.allows(toolName: "mcp__claude_ai_Slack__slack_send_message", server: server))
        #expect(!ReadOnlyTools.allows(toolName: "mcp__claude_ai_Slack__slack_send_message_draft", server: server))
        #expect(!ReadOnlyTools.allows(toolName: "mcp__claude_ai_Slack__slack_add_reaction", server: server))
        // «Прочитать и удалить» — всё равно нет.
        #expect(!ReadOnlyTools.allows(toolName: "mcp__claude_ai_Slack__read_and_delete", server: server))
        // Без читающего глагола — нет.
        #expect(!ReadOnlyTools.allows(toolName: "mcp__claude_ai_Slack__slack_magic", server: server))
        // Чужой сервер — нет.
        #expect(!ReadOnlyTools.allows(toolName: "mcp__claude_ai_Notion__notion_search", server: server))
        // Встроенные инструменты — нет.
        #expect(!ReadOnlyTools.allows(toolName: "Bash", server: server))
    }

    @Test("готовые запросы для известных серверов и свой запрос поверх")
    func presets() {
        #expect(MCPSourcePresets.query(forServer: "claude.ai GitHub")?.contains("pull request") == true)
        #expect(MCPSourcePresets.query(forServer: "my-tool") == nil)
        #expect(MCPSource(enabled: true).effectiveQuery(forServer: "claude.ai Slack")?.contains("Упоминания") == true)
        #expect(MCPSource(enabled: true, query: "свой").effectiveQuery(forServer: "claude.ai Slack") == "свой")
        #expect(MCPSource(enabled: true).effectiveQuery(forServer: "my-tool") == nil)
    }

    @Test("сводки сервисов попадают в запрос подсказок")
    func notesInPrompt() {
        var context = SuggestionContext()
        context.serviceNotes = [.init(source: "Slack", summary: "- Саша: созвон в 15:00")]
        #expect(context.prompt().contains("Из Slack:\n- Саша: созвон в 15:00"))
    }

    @Test("сбор сводки: разрешает только чтение, берёт итоговый текст")
    @MainActor
    func digestAnswersPermissions() async throws {
        let backend = FakeBackend()
        let digest = MCPDigest(backend: backend, timeout: .seconds(5))
        let task = Task { await digest.collect(server: "claude.ai Slack", query: "упоминания") }

        var connection: FakeBackend.Connection?
        let deadline = ContinuousClock.now + .seconds(5)
        while connection == nil, ContinuousClock.now < deadline {
            connection = backend.connections.first
            try await Task.sleep(for: .milliseconds(10))
        }
        let live = try #require(connection)
        #expect(live.controls == [.initialize, .mcpStatus])
        #expect(live.sent.isEmpty)
        // Сервер ещё подключается — Runie переспрашивает; подключился — задаёт вопрос.
        live.continuation.yield(.event(.controlResponse(ControlResponse(
            requestID: live.controlIDs[1], isSuccess: true,
            body: .object(["mcpServers": .array([.object(["name": .string("claude.ai Slack"), "status": .string("pending")])])]),
            error: nil))))
        let waitAgain = ContinuousClock.now + .seconds(5)
        while live.controls.count < 3, ContinuousClock.now < waitAgain {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(live.controls.last == .mcpStatus)
        live.continuation.yield(.event(.controlResponse(ControlResponse(
            requestID: live.controlIDs[2], isSuccess: true,
            body: .object(["mcpServers": .array([.object(["name": .string("claude.ai Slack"), "status": .string("connected")])])]),
            error: nil))))
        let waitSent = ContinuousClock.now + .seconds(5)
        while live.sent.isEmpty, ContinuousClock.now < waitSent {
            try await Task.sleep(for: .milliseconds(20))
        }
        let read = PermissionRequest(requestID: "r1", toolUseID: nil, toolName: "mcp__claude_ai_Slack__slack_search_messages", input: .object([:]), reason: nil)
        let send = PermissionRequest(requestID: "r2", toolUseID: nil, toolName: "mcp__claude_ai_Slack__slack_send_message", input: .object([:]), reason: nil)
        live.continuation.yield(.event(.permissionRequested(read)))
        live.continuation.yield(.event(.permissionRequested(send)))
        live.continuation.yield(.event(.assistantText(AssistantText(text: "- Саша упомянул тебя", messageID: "m", parentToolUseID: nil))))
        live.continuation.yield(.event(.turnCompleted(TurnSummary(result: nil, durationMilliseconds: nil, costUSD: nil, turnCount: nil, permissionDenialCount: 0))))

        let summary = await task.value
        #expect(summary == "- Саша упомянул тебя")
        #expect(live.responses.map(\.1) == [.allow, .deny(message: "При сборе сводки можно только читать.")])
        #expect(live.sent.first?.contains("упоминания") == true)
    }

    @Test("пустые сводки не уходят в подсказки")
    func emptyDigest() {
        #expect(MCPDigest.meaningful("**Нет.**") == nil)
        #expect(MCPDigest.meaningful("Нет страниц, изменённых за последние сутки. Проверено 10 страниц.") == nil)
        #expect(MCPDigest.meaningful("Ничего нового не нашлось.") == nil)
        #expect(MCPDigest.meaningful("- Нет ответа от Анны по договору") != nil)
        #expect(MCPDigest.meaningful("Изменены: «План запуска», «Бюджет»") != nil)
    }
}
