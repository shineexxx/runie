import Foundation
import RunieKit

// Инструменты, которыми Руни расширяет себя: подключает MCP-серверы и сохраняет
// навыки в свой плагин. Всё это видит только Runie — Claude Code в терминале нет.

enum RunieExtensions {
    static let plugin = RuniePlugin.standard
    /// Что-то подключено или сохранено — агенту нужно переподключиться, когда освободится.
    nonisolated(unsafe) static var onChange: (@Sendable () -> Void)?
}

private func stringArray(_ value: JSONValue?) -> [String] {
    (value?.arrayValue ?? []).compactMap(\.stringValue)
}

struct AddServiceTool: HostTool {
    let name = "add_service"
    let description = """
    Подключает MCP-сервер к Руни (только в Runie). Сначала прочитай навык runie:connect-service. \
    Ключи API не передавай значениями: перечисли их в secrets — человек введёт их в защищённом поле, \
    а в url, headers, command и args ссылайся на них как {ИМЯ_ПЕРЕМЕННОЙ}. {root} — папка плагина. \
    Сервер заработает со следующего сообщения.
    """
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "name": .object(["type": .string("string"), "description": .string("Латиницей: todoist, trello")]),
            "title": .object(["type": .string("string"), "description": .string("Как называть человеку: «Todoist»")]),
            "description": .object(["type": .string("string"), "description": .string("По-русски, что умеет")]),
            "transport": .object(["type": .string("string"), "enum": .array([.string("http"), .string("stdio")])]),
            "url": .object(["type": .string("string"), "description": .string("Для http: адрес https://")]),
            "headers": .object(["type": .string("object"), "description": .string("Для http: заголовки, ключ как {ПЕРЕМЕННАЯ}"),
                                "additionalProperties": .object(["type": .string("string")])]),
            "command": .object(["type": .string("string"), "description": .string("Для stdio: команда запуска")]),
            "args": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
            "secrets": .object([
                "type": .string("array"),
                "description": .string("Ключи, которые введёт человек"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "variable": .object(["type": .string("string"), "description": .string("Имя переменной: TODOIST_API_TOKEN")]),
                        "label": .object(["type": .string("string"), "description": .string("По-русски: «Токен API Todoist»")]),
                        "hint": .object(["type": .string("string"), "description": .string("Где взять ключ в сервисе")])
                    ]),
                    "required": .array([.string("variable"), .string("label")])
                ])
            ])
        ]),
        "required": .array([.string("name"), .string("description"), .string("transport")])
    ])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        let secrets = (arguments["secrets"]?.arrayValue ?? []).compactMap { item -> RuniePlugin.SecretField? in
            guard let variable = item["variable"]?.stringValue, let label = item["label"]?.stringValue else { return nil }
            return .init(variable: variable, label: label, hint: item["hint"]?.stringValue)
        }
        var headers: [String: String] = [:]
        if case .object(let values)? = arguments["headers"] {
            for (key, value) in values { headers[key] = value.stringValue }
        }
        let server = RuniePlugin.Server(
            name: arguments["name"]?.stringValue ?? "",
            description: arguments["description"]?.stringValue ?? "",
            transport: arguments["transport"]?.stringValue == "http" ? .http : .stdio,
            url: arguments["url"]?.stringValue,
            command: arguments["command"]?.stringValue,
            args: stringArray(arguments["args"]),
            secrets: secrets,
            headers: headers
        )
        do {
            try RunieExtensions.plugin.addServer(server)
        } catch {
            return HostToolResult(error.localizedDescription, isError: true)
        }

        let title = arguments["title"]?.stringValue ?? server.name
        let missing = secrets.filter {
            SecretStore.value(for: RuniePlugin.environmentVariable(server: server.name, variable: $0.variable)) == nil
        }
        var keyNote = ""
        if !missing.isEmpty {
            let entered = await SecretBroker.shared.request(serverName: server.name, title: title, fields: missing)
            keyNote = entered
                ? " Человек ввёл ключ, он сохранён в Связке ключей."
                : " Человек не ввёл ключ: без него сервер работать не будет. Предложи ввести его позже — повтори add_service."
        }
        RunieExtensions.onChange?()
        return HostToolResult("Сервер «\(title)» подключён к Runie как \(server.qualifiedName).\(keyNote) Он заработает со следующего сообщения человека.")
    }
}

struct RemoveServiceTool: HostTool {
    let name = "remove_service"
    let description = "Отключает сервер, который Руни подключил сам, и удаляет его ключи и код."
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["name": .object(["type": .string("string")])]),
        "required": .array([.string("name")])
    ])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        let name = arguments["name"]?.stringValue ?? ""
        let secrets = RunieExtensions.plugin.servers().first { $0.name == name }?.secrets ?? []
        // У Телеграма, кроме записи о сервере, есть фоновая служба и накопленная
        // переписка: отключаем — значит убираем и их.
        var extra = ""
        if TelegramExtension.matches(name) {
            extra = " " + (TelegramExtension.remove(plugin: RunieExtensions.plugin) ?? "")
        }
        do {
            try RunieExtensions.plugin.removeServer(named: name)
        } catch {
            return HostToolResult(error.localizedDescription, isError: true)
        }
        for secret in secrets {
            SecretStore.delete(RuniePlugin.environmentVariable(server: name, variable: secret.variable))
        }
        RunieExtensions.onChange?()
        return HostToolResult("Сервер «\(name)» отключён, ключи удалены." + extra)
    }
}

struct SaveSkillTool: HostTool {
    let name = "save_skill"
    let description = """
    Сохраняет навык Руни (только в Runie): инструкцию для повторяющейся задачи. Сначала прочитай навык \
    runie:create-skill. Тем же именем навык перезаписывается. Работает со следующего сообщения.
    """
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "name": .object(["type": .string("string"), "description": .string("Латиницей через дефис")]),
            "description": .object(["type": .string("string"), "description": .string("Что делает и когда вызывать")]),
            "instructions": .object(["type": .string("string"), "description": .string("Markdown: шаги и правила")])
        ]),
        "required": .array([.string("name"), .string("description"), .string("instructions")])
    ])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        let skill = RuniePlugin.Skill(
            name: arguments["name"]?.stringValue ?? "",
            description: arguments["description"]?.stringValue ?? "",
            instructions: arguments["instructions"]?.stringValue ?? ""
        )
        do {
            try RunieExtensions.plugin.saveSkill(skill)
        } catch {
            return HostToolResult(error.localizedDescription, isError: true)
        }
        RunieExtensions.onChange?()
        return HostToolResult("Навык runie:\(skill.name) сохранён. Он заработает со следующего сообщения человека.")
    }
}

struct RemoveSkillTool: HostTool {
    let name = "remove_skill"
    let description = "Удаляет навык, который Руни сохранил сам."
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["name": .object(["type": .string("string")])]),
        "required": .array([.string("name")])
    ])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        let name = arguments["name"]?.stringValue ?? ""
        do {
            try RunieExtensions.plugin.removeSkill(named: name)
        } catch {
            return HostToolResult(error.localizedDescription, isError: true)
        }
        RunieExtensions.onChange?()
        return HostToolResult("Навык «\(name)» удалён.")
    }
}

struct ListExtensionsTool: HostTool {
    let name = "list_extensions"
    let description = "Серверы и навыки, которые Руни подключил и сохранил сам, и папка его плагина."
    let inputSchema: JSONValue = .object(["type": .string("object"), "properties": .object([:])])

    func call(_ arguments: JSONValue) async -> HostToolResult {
        let plugin = RunieExtensions.plugin
        var lines = ["Папка плагина ({root}): \(plugin.root.path)"]
        let servers = plugin.servers()
        lines.append(servers.isEmpty ? "Серверов нет." : "Серверы:")
        for server in servers {
            let target = server.url ?? ([server.command ?? ""] + server.args).joined(separator: " ")
            let keys = server.secrets.map { secret in
                let saved = SecretStore.value(for: RuniePlugin.environmentVariable(server: server.name, variable: secret.variable)) != nil
                return "\(secret.variable) \(saved ? "введён" : "не введён")"
            }
            lines.append("- \(server.name) (\(server.qualifiedName)): \(server.description) — \(target)"
                         + (keys.isEmpty ? "" : "; ключи: " + keys.joined(separator: ", ")))
        }
        let skills = plugin.customSkills()
        lines.append(skills.isEmpty ? "Своих навыков нет." : "Навыки:")
        for skill in skills {
            lines.append("- runie:\(skill.name): \(skill.description)")
        }
        return HostToolResult(lines.joined(separator: "\n"))
    }
}
