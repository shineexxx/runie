import Foundation

/// Навык Claude Code: имя, описание из SKILL.md и откуда он.
public struct SkillInfo: Sendable, Equatable, Identifiable {
    public init(name: String, description: String?, path: String?, source: String) {
        self.name = name
        self.description = description
        self.path = path
        self.source = source
    }

    public let name: String
    public let description: String?
    /// Папка навыка, если нашлась.
    public let path: String?
    /// «Мои навыки» или имя плагина.
    public let source: String

    public var id: String { name }
}

extension SkillInfo {
    /// Навыки из списка команд в ответе на `initialize` — он приходит сразу, ещё до
    /// первого сообщения. Навыки там помечены в конце описания: «(user)», «(project)»
    /// или «(плагин) (user)»; встроенные команды пометок не имеют.
    public static func fromCommands(_ body: JSONValue?) -> [SkillInfo] {
        (body?["commands"]?.arrayValue ?? []).compactMap { command in
            guard let name = command["name"]?.stringValue,
                  var description = command["description"]?.stringValue
            else { return nil }
            var tags: [String] = []
            while description.hasSuffix(")"), let open = description.lastIndex(of: "(") {
                tags.insert(String(description[description.index(after: open)..<description.index(before: description.endIndex)]), at: 0)
                description = String(description[..<open]).trimmingCharacters(in: .whitespaces)
            }
            guard let scope = tags.last, scope == "user" || scope == "project" else { return nil }
            let source = tags.count > 1 ? tags[tags.count - 2] : (scope == "user" ? "Мои навыки" : "Навыки проекта")
            return SkillInfo(name: name, description: description.isEmpty ? nil : description, path: nil, source: source)
        }
    }
}

/// Находит описания навыков: `~/.claude/skills/<имя>/SKILL.md` и навыки плагинов.
public enum SkillCatalog {

    public static func load(names: [String], plugins: [PluginInfo], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [SkillInfo] {
        let userSkills = home.appending(path: ".claude/skills", directoryHint: .isDirectory)
        return names.map { name in
            let candidates: [(URL, String)] = [(userSkills.appending(path: name), "Мои навыки")]
                + plugins.map { (URL(fileURLWithPath: $0.path).appending(path: "skills/\(name)"), $0.name) }
            for (folder, source) in candidates {
                let file = folder.appending(path: "SKILL.md")
                if let text = try? String(contentsOf: file, encoding: .utf8) {
                    return SkillInfo(name: name, description: frontmatter(text)["description"], path: folder.path, source: source)
                }
            }
            return SkillInfo(name: name, description: nil, path: nil, source: "Claude Code")
        }
    }

    /// Поля между `---` в начале файла. Многострочные значения (`|`, `>`) склеиваются.
    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var fields: [String: String] = [:]
        var currentKey: String?
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            if let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if value == "|" || value == ">" || value == ">-" || value == "|-" { value = "" }
                fields[key] = unquote(value)
                currentKey = key
            } else if let key = currentKey {
                let piece = line.trimmingCharacters(in: .whitespaces)
                guard !piece.isEmpty else { continue }
                fields[key] = [fields[key] ?? "", piece].filter { !$0.isEmpty }.joined(separator: " ")
            }
        }
        return fields
    }

    /// Текст после шапки `---`; без шапки — весь файл.
    static func body(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") else { return value }
        return String(value.dropFirst().dropLast())
    }
}
