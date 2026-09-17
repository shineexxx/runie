import Foundation
import Testing
@testable import RunieKit

@Suite("Плагин Руни")
struct RuniePluginTests {

    private func makePlugin() throws -> RuniePlugin {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runie-plugin-\(UUID().uuidString)")
        let plugin = RuniePlugin(root: root)
        try plugin.prepare()
        return plugin
    }

    @Test("подготовка: манифест, пустой .mcp.json, встроенные навыки с файлами")
    func prepare() throws {
        let plugin = try makePlugin()
        let manifest = try JSONValue.decode(Data(contentsOf: plugin.root.appendingPathComponent(".claude-plugin/plugin.json")))
        #expect(manifest["name"]?.stringValue == "runie")
        let skill = try String(contentsOf: plugin.skillsURL.appendingPathComponent("connect-service/SKILL.md"), encoding: .utf8)
        #expect(skill.hasPrefix("---\nname: connect-service\ndescription: \""))
        #expect(SkillCatalog.frontmatter(skill)["description"]?.contains("Todoist") == true)
        #expect(FileManager.default.fileExists(atPath: plugin.skillsURL.appendingPathComponent("connect-service/custom-server.md").path))
        #expect(plugin.customSkills().isEmpty)
    }

    @Test("удалённый сервер: ключ в заголовке — ссылкой на переменную")
    func httpServer() throws {
        let plugin = try makePlugin()
        let server = RuniePlugin.Server(
            name: "todoist", description: "Задачи", transport: .http,
            url: "https://mcp.todoist.com/mcp",
            secrets: [.init(variable: "API_TOKEN", label: "Токен")],
            headers: ["Authorization": "Bearer {API_TOKEN}"]
        )
        try plugin.addServer(server)
        let mcp = try JSONValue.decode(Data(contentsOf: plugin.root.appendingPathComponent(".mcp.json")))
        let entry = mcp["mcpServers"]?["todoist"]
        #expect(entry?["type"]?.stringValue == "http")
        #expect(entry?["headers"]?["Authorization"]?.stringValue == "Bearer ${RUNIE_SECRET_TODOIST_API_TOKEN}")
        #expect(plugin.servers() == [server])
        #expect(server.qualifiedName == "plugin:runie:todoist")
    }

    @Test("локальный сервер: {root} и ключи в env; удаление убирает и код")
    func stdioServer() throws {
        let plugin = try makePlugin()
        let code = plugin.serversURL.appendingPathComponent("weather")
        try FileManager.default.createDirectory(at: code, withIntermediateDirectories: true)
        try Data("print(1)".utf8).write(to: code.appendingPathComponent("server.py"))
        try plugin.addServer(.init(
            name: "weather", description: "Погода", transport: .stdio,
            command: "/usr/bin/python3", args: ["{root}/servers/weather/server.py"],
            secrets: [.init(variable: "KEY", label: "Ключ")]
        ))
        let entry = try JSONValue.decode(Data(contentsOf: plugin.root.appendingPathComponent(".mcp.json")))["mcpServers"]?["weather"]
        #expect(entry?["args"]?.arrayValue?.first?.stringValue == "${CLAUDE_PLUGIN_ROOT}/servers/weather/server.py")
        #expect(entry?["env"]?["KEY"]?.stringValue == "${RUNIE_SECRET_WEATHER_KEY}")

        try plugin.removeServer(named: "weather")
        #expect(plugin.servers().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: code.path))
        #expect(throws: RuniePlugin.Failure.notFound("weather")) { try plugin.removeServer(named: "weather") }
    }

    @Test("проверки: имя, https, команда, переменная")
    func validation() throws {
        let plugin = try makePlugin()
        #expect(throws: RuniePlugin.Failure.badName("../evil")) {
            try plugin.addServer(.init(name: "../evil", description: "", transport: .stdio, command: "x"))
        }
        #expect(throws: RuniePlugin.Failure.self) {
            try plugin.addServer(.init(name: "plain", description: "", transport: .http, url: "http://example.com"))
        }
        #expect(throws: RuniePlugin.Failure.self) {
            try plugin.addServer(.init(name: "empty", description: "", transport: .stdio))
        }
        #expect(throws: RuniePlugin.Failure.self) {
            try plugin.addServer(.init(name: "vars", description: "", transport: .stdio, command: "x",
                                       secrets: [.init(variable: "BAD NAME", label: "")]))
        }
    }

    @Test("навыки: сохранение, перезапись, встроенные защищены")
    func skills() throws {
        let plugin = try makePlugin()
        try plugin.saveSkill(.init(name: "weekly-report", description: "Отчёт: «за неделю»", instructions: "1. Собери"))
        try plugin.saveSkill(.init(name: "weekly-report", description: "Отчёт по пятницам", instructions: "2. Отправь"))
        #expect(plugin.customSkills().map(\.description) == ["Отчёт по пятницам"])
        #expect(throws: RuniePlugin.Failure.builtIn("create-skill")) {
            try plugin.saveSkill(.init(name: "create-skill", description: "x", instructions: "y"))
        }
        #expect(throws: RuniePlugin.Failure.builtIn("connect-service")) { try plugin.removeSkill(named: "connect-service") }
        try plugin.removeSkill(named: "weekly-report")
        #expect(plugin.customSkills().isEmpty)
    }

    @Test("аргументы: папка плагина, переменная ключа, группа разрешений")
    func wiring() {
        var arguments = ClaudeCodeArguments()
        arguments.pluginDirectories = ["/tmp/runie"]
        let built = arguments.build()
        let index = built.firstIndex(of: "--plugin-dir")
        #expect(index.map { built[$0 + 1] } == "/tmp/runie")
        #expect(RuniePlugin.environmentVariable(server: "my-api", variable: "token") == "RUNIE_SECRET_MY_API_TOKEN")
        #expect(PermissionClassifier.categories(toolName: "mcp__runie__add_service", input: .object([:])) == [.extendRunie])
        #expect(PermissionClassifier.categories(toolName: "mcp__plugin_runie_todoist__list_tasks", input: .object([:])) == [.services])
        #expect(PermissionCategory.extendRunie.isRisky)
    }
}
