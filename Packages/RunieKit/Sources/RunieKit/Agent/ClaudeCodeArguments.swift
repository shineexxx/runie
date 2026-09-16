import Foundation

/// Собирает аргументы запуска Claude Code.
///
/// Единственное место в коде, которое знает имена флагов. Когда CLI их поменяет,
/// чинить придётся здесь, а не по всему приложению.
public struct ClaudeCodeArguments: Sendable, Equatable {

    /// Кто отвечает на запросы разрешений.
    public enum PermissionPrompts: String, Sendable {
        /// Отвечает хост через `permissionPromptTool`.
        ///
        /// Проверено на CLI 2.1.272: если инструмент не задан, отвечать некому, и CLI
        /// сразу отказывает сам, присылая `system/permission_denied`.
        case host
        /// Никто: всё, что потребовало бы подтверждения, отклоняется само.
        case none
    }

    /// Новая сессия со своим идентификатором или продолжение существующей.
    public enum Session: Sendable, Equatable {
        case new(id: UUID)
        case resume(id: String)
    }

    public var session: Session
    public var permissionMode: String
    public var permissionPrompts: PermissionPrompts
    /// Через что CLI спрашивает разрешение у приложения. `stdio` — управляющие
    /// сообщения прямо в потоке stream-json, как у Agent SDK.
    public var permissionPromptTool: String?
    /// Дописывается к системному промпту Claude Code.
    public var appendSystemPrompt: String?
    /// Пути к JSON-конфигурациям MCP-серверов.
    public var mcpConfigPaths: [String]
    /// MCP-серверы, которые живут в самом приложении: CLI обращается к ним через
    /// управляющий протокол. Серверы пользователя из настроек Claude Code остаются.
    public var hostToolServers: [String] = []
    /// Правила запрета инструментов: `Skill(имя)`, `mcp__сервер`…
    public var disallowedTools: [String] = []
    /// Брать MCP только из переданных конфигураций, игнорируя пользовательские.
    public var strictMCPConfig: Bool
    /// Отдавать текст ответа кусками по мере написания, а не целым блоком.
    public var includePartialMessages: Bool
    public var additionalArguments: [String]

    public init(
        session: Session = .new(id: UUID()),
        permissionMode: String = "manual",
        permissionPrompts: PermissionPrompts = .host,
        permissionPromptTool: String? = "stdio",
        appendSystemPrompt: String? = nil,
        mcpConfigPaths: [String] = [],
        strictMCPConfig: Bool = false,
        includePartialMessages: Bool = true,
        additionalArguments: [String] = []
    ) {
        self.session = session
        self.permissionMode = permissionMode
        self.permissionPrompts = permissionPrompts
        self.permissionPromptTool = permissionPromptTool
        self.appendSystemPrompt = appendSystemPrompt
        self.mcpConfigPaths = mcpConfigPaths
        self.strictMCPConfig = strictMCPConfig
        self.includePartialMessages = includePartialMessages
        self.additionalArguments = additionalArguments
    }

    public func build() -> [String] {
        var arguments = [
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            // Без --verbose поток stream-json приходит урезанным: вызовы инструментов
            // и системные события не видны, а именно они и есть «руки» в интерфейсе.
            "--verbose"
        ]

        if includePartialMessages {
            arguments.append("--include-partial-messages")
        }

        switch session {
        case .new(let id):
            arguments += ["--session-id", id.uuidString.lowercased()]
        case .resume(let id):
            arguments += ["--resume", id]
        }

        arguments += ["--permission-mode", permissionMode]
        arguments += ["--permission-prompts", permissionPrompts.rawValue]

        if let permissionPromptTool {
            arguments += ["--permission-prompt-tool", permissionPromptTool]
        }
        if let appendSystemPrompt {
            arguments += ["--append-system-prompt", appendSystemPrompt]
        }
        if !hostToolServers.isEmpty {
            var servers: [String: JSONValue] = [:]
            for name in hostToolServers {
                servers[name] = .object(["type": .string("sdk"), "name": .string(name)])
            }
            arguments += ["--mcp-config", JSONValue.object(["mcpServers": .object(servers)]).jsonString()]
        }
        if !disallowedTools.isEmpty {
            arguments += ["--disallowedTools", disallowedTools.joined(separator: ",")]
        }
        for path in mcpConfigPaths {
            arguments += ["--mcp-config", path]
        }
        if strictMCPConfig {
            arguments.append("--strict-mcp-config")
        }

        return arguments + additionalArguments
    }
}
