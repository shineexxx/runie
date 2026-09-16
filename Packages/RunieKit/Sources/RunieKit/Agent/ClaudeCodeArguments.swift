import Foundation

/// Собирает аргументы запуска Claude Code.
///
/// Единственное место в коде, которое знает имена флагов. Когда CLI их поменяет,
/// чинить придётся здесь, а не по всему приложению.
public struct ClaudeCodeArguments: Sendable, Equatable {

    /// Кто отвечает на запросы разрешений.
    public enum PermissionPrompts: String, Sendable {
        /// Отвечает приложение. Это режим Runie: подтверждение показывается человеку.
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
    /// Имя инструмента, через который CLI спрашивает разрешение у приложения.
    /// Появится на шаге 5 вместе с брокером.
    public var permissionPromptTool: String?
    /// Пути к JSON-конфигурациям MCP-серверов.
    public var mcpConfigPaths: [String]
    /// Брать MCP только из переданных конфигураций, игнорируя пользовательские.
    public var strictMCPConfig: Bool
    public var additionalArguments: [String]

    public init(
        session: Session = .new(id: UUID()),
        permissionMode: String = "manual",
        permissionPrompts: PermissionPrompts = .host,
        permissionPromptTool: String? = nil,
        mcpConfigPaths: [String] = [],
        strictMCPConfig: Bool = false,
        additionalArguments: [String] = []
    ) {
        self.session = session
        self.permissionMode = permissionMode
        self.permissionPrompts = permissionPrompts
        self.permissionPromptTool = permissionPromptTool
        self.mcpConfigPaths = mcpConfigPaths
        self.strictMCPConfig = strictMCPConfig
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
        for path in mcpConfigPaths {
            arguments += ["--mcp-config", path]
        }
        if strictMCPConfig {
            arguments.append("--strict-mcp-config")
        }

        return arguments + additionalArguments
    }
}
