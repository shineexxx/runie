import Foundation
import Testing
@testable import RunieKit

@Suite("Расширения: серверы и навыки")
struct ExtensionsTests {

    @Test("ответ mcp_status разбирается — форма снята с CLI 2.1.272")
    func parsesMCPStatus() throws {
        let body = try JSONValue.decode(Data(#"""
        {"mcpServers":[
          {"name":"claude.ai Gmail","status":"needs-auth","config":{"type":"claudeai-proxy","url":"https://gmailmcp.googleapis.com/mcp/v1"},"scope":"claudeai"},
          {"name":"files","status":"connected","config":{"type":"stdio","command":"npx","args":["-y","mcp-files"]},"scope":"user"},
          {"name":"odd","status":"weird"}
        ]}
        """#.utf8))
        let servers = MCPServerInfo.list(from: body)
        #expect(servers.map(\.status) == [.needsAuth, .connected, .unknown])
        #expect(servers[0].target == "https://gmailmcp.googleapis.com/mcp/v1")
        #expect(servers[1].target == "npx -y mcp-files")
        #expect(servers[1].scope == "user")
    }

    @Test("управляющие запросы mcp_status и mcp_toggle")
    func encodesRequests() throws {
        let toggle = try JSONValue.decode(ControlRequest.mcpToggle(name: "claude.ai Slack", enabled: false).ndjsonLine(requestID: "t"))
        #expect(toggle.path("request", "subtype")?.stringValue == "mcp_toggle")
        #expect(toggle.path("request", "serverName")?.stringValue == "claude.ai Slack")
        #expect(toggle.path("request", "enabled")?.boolValue == false)
    }

    @Test("init несёт навыки и плагины")
    func initCarriesSkills() throws {
        let raw = RawAgentEvent(payload: try JSONValue.decode(Data(#"""
        {"type":"system","subtype":"init","session_id":"s","skills":["brand","careful"],"plugins":[{"name":"swift-lsp","path":"/p/swift-lsp"}]}
        """#.utf8)))
        guard case .sessionStarted(let info) = AgentEventNormalizer().normalize(raw).first else {
            Issue.record("нет sessionStarted"); return
        }
        #expect(info.skills == ["brand", "careful"])
        #expect(info.plugins == [PluginInfo(name: "swift-lsp", path: "/p/swift-lsp")])
    }

    @Test("описание навыка из SKILL.md, в том числе многострочное")
    func readsSkillDescriptions() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "runie-home-\(UUID().uuidString)")
        let folder = home.appending(path: ".claude/skills/brand")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "---\nname: brand\ndescription: |\n  Фирменный стиль.\n  Цвета и шрифты.\n---\n# текст".write(
            to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let skills = SkillCatalog.load(names: ["brand", "missing"], plugins: [], home: home)
        #expect(skills[0].description == "Фирменный стиль. Цвета и шрифты.")
        #expect(skills[0].source == "Мои навыки")
        #expect(skills[1].description == nil)
        #expect(SkillCatalog.frontmatter("---\ndescription: \"В кавычках\"\n---")["description"] == "В кавычках")
    }

    @Test("навыки из команд initialize: пометки источника, встроенные команды отброшены")
    func skillsFromCommands() throws {
        let body = try JSONValue.decode(Data(#"""
        {"commands":[
          {"name":"careful","description":"Safety guardrails for destructive commands. (gstack) (user)"},
          {"name":"brand","description":"Фирменный стиль (user)"},
          {"name":"compact","description":"Clear conversation history but keep a summary"},
          {"name":"resume","description":"Resume a session (resumable with /resume)"}
        ]}
        """#.utf8))
        let skills = SkillInfo.fromCommands(body)
        #expect(skills.map(\.name) == ["careful", "brand"])
        #expect(skills[0].description == "Safety guardrails for destructive commands.")
        #expect(skills[0].source == "gstack")
        #expect(skills[1].source == "Мои навыки")
    }

    @Test("выключенные навыки уходят правилами Skill(…) при подключении")
    @MainActor
    func disabledSkillsPassedOnConnect() throws {
        let backend = FakeBackend()
        let session = ChatSession(backend: backend)
        session.disabledSkills = ["careful", "brand"]
        session.disabledMCPServers = ["claude.ai Slack"]
        session.prepare()
        #expect(backend.disallowed.last == ["Skill(brand)", "Skill(careful)", "mcp__claude_ai_Slack"])
        #expect(MCPServerInfo.denyRule(forServer: "my-server_2") == "mcp__my-server_2")

        var arguments = ClaudeCodeArguments()
        arguments.disallowedTools = ["Skill(brand)"]
        let built = arguments.build()
        #expect(built[built.firstIndex(of: "--disallowedTools")! + 1] == "Skill(brand)")
    }
}
