import Foundation
import Testing
@testable import RunieKit

@Suite("ClaudeCodeArguments")
struct ClaudeCodeArgumentsTests {

    /// Возвращает значение, идущее следом за флагом.
    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    @Test("поток в обе стороны и подробный режим включены всегда")
    func alwaysStreamsBothWays() {
        let arguments = ClaudeCodeArguments().build()
        #expect(arguments.contains("--print"))
        #expect(value(after: "--input-format", in: arguments) == "stream-json")
        #expect(value(after: "--output-format", in: arguments) == "stream-json")
        // Без --verbose не видно вызовов инструментов, а это и есть «руки» в интерфейсе.
        #expect(arguments.contains("--verbose"))
    }

    @Test("новая сессия получает наш идентификатор в нижнем регистре")
    func newSessionUsesOwnIdentifier() {
        let id = UUID()
        let arguments = ClaudeCodeArguments(session: .new(id: id)).build()
        #expect(value(after: "--session-id", in: arguments) == id.uuidString.lowercased())
        #expect(arguments.contains("--resume") == false)
    }

    @Test("продолжение сессии не назначает новый идентификатор")
    func resumeDoesNotAssignNewIdentifier() {
        let arguments = ClaudeCodeArguments(session: .resume(id: "abc-123")).build()
        #expect(value(after: "--resume", in: arguments) == "abc-123")
        #expect(arguments.contains("--session-id") == false)
    }

    @Test("по умолчанию на разрешения отвечает приложение, а не автоматика")
    func defaultsToHostAnsweringPermissions() {
        let arguments = ClaudeCodeArguments().build()
        #expect(value(after: "--permission-prompts", in: arguments) == "host")
        #expect(value(after: "--permission-mode", in: arguments) == "manual")
    }

    @Test("инструмент разрешений добавляется только когда задан")
    func permissionPromptToolIsOptional() {
        #expect(ClaudeCodeArguments().build().contains("--permission-prompt-tool") == false)

        let withTool = ClaudeCodeArguments(permissionPromptTool: "mcp__runie__approve").build()
        #expect(value(after: "--permission-prompt-tool", in: withTool) == "mcp__runie__approve")
    }

    @Test("каждая конфигурация MCP идёт своим флагом")
    func mcpConfigsAreRepeated() {
        let arguments = ClaudeCodeArguments(
            mcpConfigPaths: ["/a.json", "/b.json"],
            strictMCPConfig: true
        ).build()
        #expect(arguments.filter { $0 == "--mcp-config" }.count == 2)
        #expect(arguments.contains("/a.json"))
        #expect(arguments.contains("/b.json"))
        #expect(arguments.contains("--strict-mcp-config"))
    }

    @Test("дополнительные аргументы идут последними")
    func additionalArgumentsGoLast() {
        let arguments = ClaudeCodeArguments(additionalArguments: ["--add-dir", "/tmp"]).build()
        #expect(arguments.suffix(2) == ["--add-dir", "/tmp"])
    }
}

@Suite("UserMessage")
struct UserMessageTests {

    @Test("строка совпадает с форматом, который принимает CLI")
    func encodesExpectedShape() throws {
        let line = try UserMessage("привет").ndjsonLine()
        #expect(line.last == UInt8(ascii: "\n"))

        let value = try JSONValue.decode(line.dropLast())
        #expect(value["type"]?.stringValue == "user")
        #expect(value.path("message", "role")?.stringValue == "user")
        #expect(value.path("message", "content", 0, "type")?.stringValue == "text")
        #expect(value.path("message", "content", 0, "text")?.stringValue == "привет")
    }

    @Test("переводы строк внутри текста не ломают NDJSON")
    func escapesNewlinesInText() throws {
        let line = try UserMessage("первая\nвторая").ndjsonLine()
        // Ровно один перевод строки — тот, что завершает запись.
        #expect(line.filter { $0 == UInt8(ascii: "\n") }.count == 1)

        let value = try JSONValue.decode(line.dropLast())
        #expect(value.path("message", "content", 0, "text")?.stringValue == "первая\nвторая")
    }
}
