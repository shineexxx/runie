import Foundation
import Testing
@testable import RunieKit

private struct EchoTool: HostTool {
    let name = "say_hello"
    let description = "Приветствие"
    let inputSchema: JSONValue = .object(["type": .string("object")])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        HostToolResult("Привет, \(arguments["name"]?.stringValue ?? "?")!")
    }
}

@Suite("Встроенный MCP-сервер")
struct HostToolServerTests {

    private let server = HostToolServer(name: "runie", tools: [EchoTool()])

    @Test("initialize и tools/list — как ждёт Claude Code")
    func listsTools() async {
        let initialize = await server.handle(.object([
            "jsonrpc": .string("2.0"), "id": .int(0), "method": .string("initialize"),
            "params": .object(["protocolVersion": .string("2025-11-25")])
        ]))
        #expect(initialize.path("result", "protocolVersion")?.stringValue == "2025-11-25")
        #expect(initialize.path("result", "serverInfo", "name")?.stringValue == "runie")

        let list = await server.handle(.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("tools/list")]))
        #expect(list.path("result", "tools")?[0]?["name"]?.stringValue == "say_hello")
        #expect(list["id"] == .int(1))
    }

    @Test("tools/call вызывает инструмент; неизвестный — ошибка в результате")
    func callsTool() async {
        let call = await server.handle(.object([
            "jsonrpc": .string("2.0"), "id": .int(2), "method": .string("tools/call"),
            "params": .object(["name": .string("say_hello"), "arguments": .object(["name": .string("Аня")])])
        ]))
        #expect(call.path("result", "content")?[0]?["text"]?.stringValue == "Привет, Аня!")
        #expect(call.path("result", "isError")?.boolValue == false)

        let missing = await server.handle(.object([
            "jsonrpc": .string("2.0"), "id": .int(3), "method": .string("tools/call"),
            "params": .object(["name": .string("nope")])
        ]))
        #expect(missing.path("result", "isError")?.boolValue == true)
    }

    @Test("управляющие сообщения: разбор mcp_message, ответ mcp_response, sdk-сервер в аргументах")
    func protocolShapes() throws {
        let raw = RawAgentEvent(payload: try JSONValue.decode(Data(#"""
        {"type":"control_request","request_id":"r1","request":{"subtype":"mcp_message","server_name":"runie","message":{"jsonrpc":"2.0","id":1,"method":"tools/list"}}}
        """#.utf8)))
        guard case .mcpMessage(let message) = AgentEventNormalizer().normalize(raw).first else {
            Issue.record("не mcpMessage"); return
        }
        #expect(message.requestID == "r1")
        #expect(message.serverName == "runie")

        let reply = try JSONValue.decode(MCPReply(requestID: "r1", response: .object(["id": .int(1)])).ndjsonLine())
        #expect(reply.path("response", "request_id")?.stringValue == "r1")
        #expect(reply.path("response", "response", "mcp_response", "id") == .int(1))

        var arguments = ClaudeCodeArguments()
        arguments.hostToolServers = ["runie"]
        let built = arguments.build()
        let config = try #require(built.firstIndex(of: "--mcp-config").map { built[$0 + 1] })
        #expect(config.contains(#""type":"sdk""#))

        let initialize = try JSONValue.decode(ControlRequest.initializeWithHostServers(["runie"]).ndjsonLine(requestID: "a"))
        #expect(initialize.path("request", "sdkMcpServers")?[0]?.stringValue == "runie")
    }

    @Test("сессия отвечает на mcp_message своим сервером")
    @MainActor
    func sessionReplies() async throws {
        let backend = FakeBackend()
        let session = ChatSession(backend: backend)
        session.hostTools = server
        session.prepare()
        let connection = try #require(backend.connections.first)
        #expect(connection.controls == [.initializeWithHostServers(["runie"])])

        connection.continuation.yield(.event(.mcpMessage(MCPMessage(
            requestID: "r9", serverName: "runie",
            message: .object(["jsonrpc": .string("2.0"), "id": .int(4), "method": .string("tools/call"),
                              "params": .object(["name": .string("say_hello"), "arguments": .object(["name": .string("Саша")])])])
        ))))
        let deadline = ContinuousClock.now + .seconds(5)
        while connection.mcpReplies.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let reply = try #require(connection.mcpReplies.first)
        #expect(reply.requestID == "r9")
        #expect(reply.response.path("result", "content")?[0]?["text"]?.stringValue == "Привет, Саша!")
    }
}
