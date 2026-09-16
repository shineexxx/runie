import Foundation

/// Результат встроенного инструмента.
public struct HostToolResult: Sendable, Equatable {
    public let text: String
    public let isError: Bool

    public init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

/// Инструмент, который Runie выполняет сам, в своём процессе: нативные действия
/// macOS, которых нет у Claude Code, — Spotlight, Finder, отправка через Почту.
public protocol HostTool: Sendable {
    var name: String { get }
    var description: String { get }
    /// JSON Schema аргументов.
    var inputSchema: JSONValue { get }
    func call(_ arguments: JSONValue) async -> HostToolResult
}

/// MCP-сервер внутри приложения.
///
/// Протокол снят с CLI 2.1.272: сервер объявляется в `--mcp-config` с типом `sdk`
/// и в `initialize` полем `sdkMcpServers`; CLI присылает JSON-RPC сообщения MCP
/// (`initialize`, `tools/list`, `tools/call`) управляющими запросами `mcp_message`
/// и ждёт ответ в `mcp_response`. Разрешения на вызов идут обычным путём — через
/// вопрос `can_use_tool`.
public struct HostToolServer: Sendable {
    public let name: String
    public let version: String
    public let tools: [any HostTool]

    public init(name: String, version: String = "1.0", tools: [any HostTool]) {
        self.name = name
        self.version = version
        self.tools = tools
    }

    public func handle(_ message: JSONValue) async -> JSONValue {
        let id = message["id"] ?? .int(0)
        let method = message["method"]?.stringValue ?? ""

        switch method {
        case "initialize":
            let version = message.path("params", "protocolVersion")?.stringValue ?? "2025-06-18"
            return Self.result(id: id, .object([
                "protocolVersion": .string(version),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string(name), "version": .string(self.version)])
            ]))

        case "tools/list":
            return Self.result(id: id, .object(["tools": .array(tools.map { tool in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "inputSchema": tool.inputSchema
                ])
            })]))

        case "tools/call":
            let toolName = message.path("params", "name")?.stringValue ?? ""
            let arguments = message.path("params", "arguments") ?? .object([:])
            guard let tool = tools.first(where: { $0.name == toolName }) else {
                return Self.result(id: id, Self.content(HostToolResult("Нет инструмента \(toolName)", isError: true)))
            }
            return Self.result(id: id, Self.content(await tool.call(arguments)))

        case "ping":
            return Self.result(id: id, .object([:]))

        default:
            // Уведомления (`notifications/initialized` и другие) ответа по сути не
            // ждут, но управляющий протокол требует ответ на каждый запрос.
            if message["id"] == nil {
                return Self.result(id: .int(0), .object([:]))
            }
            return .object([
                "jsonrpc": .string("2.0"),
                "id": id,
                "error": .object(["code": .int(-32601), "message": .string("Неизвестный метод \(method)")])
            ])
        }
    }

    private static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    private static func content(_ result: HostToolResult) -> JSONValue {
        .object([
            "content": .array([.object(["type": .string("text"), "text": .string(result.text)])]),
            "isError": .bool(result.isError)
        ])
    }
}
