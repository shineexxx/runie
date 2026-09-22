import Foundation

/// Всё, чем Руни расширил себя сам: MCP-серверы и навыки.
///
/// Лежит плагином Claude Code в папке Runie и подключается флагом `--plugin-dir`
/// только к запускам Runie — настройки Claude Code в терминале не меняются.
/// Ключи API в файлах не хранятся: в конфигурации сервера стоит ссылка на
/// переменную окружения, а значение приложение берёт из Связки ключей.
public struct RuniePlugin: Sendable {

    public static let name = "runie"

    /// Папка плагина: `.claude-plugin/plugin.json`, `.mcp.json`, `skills/`, `servers/`.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/Library/Application Support/Runie/Plugin`.
    public static var standard: RuniePlugin {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return RuniePlugin(root: support.appendingPathComponent("Runie/Plugin", isDirectory: true))
    }

    private var manifestURL: URL { root.appendingPathComponent(".claude-plugin/plugin.json") }
    private var mcpURL: URL { root.appendingPathComponent(".mcp.json") }
    /// Описания серверов и какие ключи им нужны — рядом, а не в `.mcp.json`:
    /// лишние поля там CLI может счесть ошибкой.
    private var registryURL: URL { root.appendingPathComponent("runie-servers.json") }
    public var skillsURL: URL { root.appendingPathComponent("skills", isDirectory: true) }
    /// Сюда Руни кладёт код своих серверов.
    public var serversURL: URL { root.appendingPathComponent("servers", isDirectory: true) }

    // MARK: Подготовка

    /// Создаёт папки и манифест, обновляет встроенные навыки.
    public func prepare() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: skillsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: serversURL, withIntermediateDirectories: true)
        let manifest = JSONValue.object([
            "name": .string(Self.name),
            "description": .string("Серверы и навыки, которые Руни подключил и создал сам"),
            "version": .string("1.0.0")
        ])
        try Data(manifest.jsonString().utf8).write(to: manifestURL, options: .atomic)
        if !fileManager.fileExists(atPath: mcpURL.path) {
            try writeMCP([:])
        }
        for skill in BundledSkills.all {
            try writeSkill(skill)
        }
        removeReplacedServers()
    }

    /// Серверы, которые когда-то подключались плагином, а теперь встроены в Руни.
    ///
    /// Старая запись не просто лишняя: её команда ведёт на удалённый скрипт, а
    /// ключ из неё Руни спрашивает у Связки ключей при каждом подключении — и
    /// запуск мог встать на этом вопросе.
    static let replacedServers = ["telegram"]

    private func removeReplacedServers() {
        let stale = servers().filter { Self.replacedServers.contains($0.name) }
        for server in stale {
            try? removeServer(named: server.name)
        }
    }

    // MARK: Серверы

    public struct SecretField: Codable, Sendable, Equatable {
        /// Имя переменной для сервера, например `TODOIST_API_TOKEN`.
        public var variable: String
        /// Что это, по-русски: «Токен API Todoist».
        public var label: String
        /// Где взять: «Настройки → Интеграции → Токен API».
        public var hint: String?

        public init(variable: String, label: String, hint: String? = nil) {
            self.variable = variable
            self.label = label
            self.hint = hint
        }
    }

    public struct Server: Codable, Sendable, Equatable {
        public enum Transport: String, Codable, Sendable {
            case http
            case stdio
        }

        public var name: String
        public var description: String
        public var transport: Transport
        public var url: String?
        public var command: String?
        public var args: [String]
        /// Ключи, которые вводит человек. Передаются серверу переменными окружения.
        public var secrets: [SecretField]
        /// Заголовки удалённого сервера. `{ИМЯ}` подставляет ключ: `Bearer {API_TOKEN}`.
        public var headers: [String: String]

        public init(
            name: String, description: String, transport: Transport,
            url: String? = nil, command: String? = nil, args: [String] = [],
            secrets: [SecretField] = [], headers: [String: String] = [:]
        ) {
            self.name = name
            self.description = description
            self.transport = transport
            self.url = url
            self.command = command
            self.args = args
            self.secrets = secrets
            self.headers = headers
        }

        /// Как сервер называется в Claude Code: `plugin:runie:todoist`.
        public var qualifiedName: String { "plugin:\(RuniePlugin.name):\(name)" }
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case badName(String)
        case badServer(String)
        case notFound(String)
        case builtIn(String)

        public var errorDescription: String? {
            switch self {
            case .badName(let name): t("Имя «\(name)» не подходит: только латинские строчные буквы, цифры и дефис, до 40 символов.")
            case .badServer(let reason): reason
            case .notFound(let name): t("«\(name)» не найден.")
            case .builtIn(let name): t("«\(name)» — встроенный навык Руни, его нельзя заменить или удалить.")
            }
        }
    }

    public static func isValidName(_ name: String) -> Bool {
        name.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil
    }

    /// Переменная окружения, в которой Runie передаёт ключ: `RUNIE_SECRET_TODOIST_API_TOKEN`.
    public static func environmentVariable(server: String, variable: String) -> String {
        let clean = { (text: String) in
            String(text.uppercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" })
        }
        return "RUNIE_SECRET_\(clean(server))_\(clean(variable))"
    }

    public func servers() -> [Server] {
        guard let data = try? Data(contentsOf: registryURL),
              let servers = try? JSONDecoder().decode([Server].self, from: data) else { return [] }
        return servers
    }

    /// Добавляет сервер или заменяет одноимённый.
    public func addServer(_ server: Server) throws {
        guard Self.isValidName(server.name) else { throw Failure.badName(server.name) }
        for secret in server.secrets where secret.variable.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,63}$", options: .regularExpression) == nil {
            throw Failure.badServer(t("Имя переменной «\(secret.variable)» не подходит: латиница, цифры и _."))
        }
        let entry = try mcpEntry(for: server)
        var all = servers().filter { $0.name != server.name }
        all.append(server)
        var mcp = readMCP()
        mcp[server.name] = entry
        try writeMCP(mcp)
        try writeRegistry(all)
    }

    public func removeServer(named name: String) throws {
        var mcp = readMCP()
        let known = servers()
        guard mcp[name] != nil || known.contains(where: { $0.name == name }) else { throw Failure.notFound(name) }
        mcp[name] = nil
        try writeMCP(mcp)
        try writeRegistry(known.filter { $0.name != name })
        // Код своего сервера уходит вместе с ним.
        let code = serversURL.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: code.path) {
            try FileManager.default.removeItem(at: code)
        }
    }

    /// Запись для `.mcp.json`: ключи — ссылками на переменные окружения,
    /// `{root}` в аргументах — папка плагина.
    func mcpEntry(for server: Server) throws -> JSONValue {
        let placeholders = Dictionary(uniqueKeysWithValues: server.secrets.map {
            ($0.variable, "${\(Self.environmentVariable(server: server.name, variable: $0.variable))}")
        })
        func substitute(_ text: String) -> String {
            var result = text.replacingOccurrences(of: "{root}", with: "${CLAUDE_PLUGIN_ROOT}")
            for (variable, reference) in placeholders {
                result = result.replacingOccurrences(of: "{\(variable)}", with: reference)
            }
            return result
        }

        switch server.transport {
        case .http:
            guard let url = server.url, let parsed = URL(string: url), parsed.scheme == "https", parsed.host != nil else {
                throw Failure.badServer(t("Удалённому серверу нужен адрес https://."))
            }
            var entry: [String: JSONValue] = ["type": .string("http"), "url": .string(url)]
            if !server.headers.isEmpty {
                entry["headers"] = .object(server.headers.mapValues { .string(substitute($0)) })
            }
            return .object(entry)
        case .stdio:
            guard let command = server.command, !command.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw Failure.badServer(t("Локальному серверу нужна команда запуска."))
            }
            var entry: [String: JSONValue] = [
                "command": .string(substitute(command)),
                "args": .array(server.args.map { .string(substitute($0)) })
            ]
            if !server.secrets.isEmpty {
                entry["env"] = .object(Dictionary(uniqueKeysWithValues: server.secrets.map {
                    ($0.variable, .string(placeholders[$0.variable]!))
                }))
            }
            return .object(entry)
        }
    }

    private func readMCP() -> [String: JSONValue] {
        guard let data = try? Data(contentsOf: mcpURL),
              let value = try? JSONValue.decode(data),
              case .object(let servers)? = value["mcpServers"] else { return [:] }
        return servers
    }

    private func writeMCP(_ servers: [String: JSONValue]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(JSONValue.object(["mcpServers": .object(servers)]).jsonString().utf8).write(to: mcpURL, options: .atomic)
    }

    private func writeRegistry(_ servers: [Server]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(servers.sorted { $0.name < $1.name }).write(to: registryURL, options: .atomic)
    }

    // MARK: Навыки

    public struct Skill: Sendable, Equatable {
        public var name: String
        public var description: String
        public var instructions: String
        /// Дополнительные файлы рядом с SKILL.md: имя → текст.
        public var files: [String: String]

        public init(name: String, description: String, instructions: String, files: [String: String] = [:]) {
            self.name = name
            self.description = description
            self.instructions = instructions
            self.files = files
        }

        public var isBuiltIn: Bool { BundledSkills.all.contains { $0.name == name } }

        /// Текст SKILL.md. Описание — в кавычках JSON: двоеточия и кавычки внутри
        /// не ломают заголовок.
        var markdown: String {
            let quoted = JSONValue.string(description.replacingOccurrences(of: "\n", with: " ")).jsonString()
            return "---\nname: \(name)\ndescription: \(quoted)\n---\n\n" + instructions.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }
    }

    /// Навыки, которые Руни сохранил сам, — без встроенных.
    public func customSkills() -> [Skill] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: skillsURL, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder -> Skill? in
            let name = folder.lastPathComponent
            guard !BundledSkills.all.contains(where: { $0.name == name }),
                  let text = try? String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8)
            else { return nil }
            let frontmatter = SkillCatalog.frontmatter(text)
            return Skill(name: name, description: frontmatter["description"] ?? "", instructions: "")
        }
        .sorted { $0.name < $1.name }
    }

    public func saveSkill(_ skill: Skill) throws {
        guard Self.isValidName(skill.name) else { throw Failure.badName(skill.name) }
        guard !skill.isBuiltIn else { throw Failure.builtIn(skill.name) }
        guard !skill.description.trimmingCharacters(in: .whitespaces).isEmpty,
              !skill.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.badServer(t("Навыку нужны описание и инструкция."))
        }
        try writeSkill(skill)
    }

    public func removeSkill(named name: String) throws {
        guard !BundledSkills.all.contains(where: { $0.name == name }) else { throw Failure.builtIn(name) }
        let folder = skillsURL.appendingPathComponent(name, isDirectory: true)
        guard Self.isValidName(name), FileManager.default.fileExists(atPath: folder.path) else { throw Failure.notFound(name) }
        try FileManager.default.removeItem(at: folder)
    }

    private func writeSkill(_ skill: Skill) throws {
        let folder = skillsURL.appendingPathComponent(skill.name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(skill.markdown.utf8).write(to: folder.appendingPathComponent("SKILL.md"), options: .atomic)
        for (file, text) in skill.files {
            let name = (file as NSString).lastPathComponent
            try Data(text.utf8).write(to: folder.appendingPathComponent(name), options: .atomic)
        }
    }
}
