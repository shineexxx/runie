import Foundation

/// Быстрая команда: инструкция, которую человек написал в настройках. Вызывается
/// через `/команда` или сама, когда человек просит что-то похожее. Для Claude Code
/// это обычный навык плагина Runie, а название, слово для «/» и фразы лежат рядом.
public struct QuickCommand: Codable, Sendable, Equatable, Identifiable {
    /// Имя навыка латиницей — папка в `skills/`.
    public var name: String
    /// Как человек её называет: «Недельный отчёт».
    public var title: String
    /// Слово после «/», без самой косой черты: «отчёт».
    public var command: String
    /// Какими словами о ней обычно просят.
    public var phrases: [String]
    /// Что делать.
    public var instructions: String

    public var id: String { name }

    public init(name: String = "", title: String, command: String, phrases: [String] = [], instructions: String) {
        self.name = name
        self.title = title
        self.command = command
        self.phrases = phrases
        self.instructions = instructions
    }

    /// Слово для «/» без лишнего: без косой черты, пробелов и регистра.
    public static func normalize(_ command: String) -> String {
        var word = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while word.hasPrefix("/") { word.removeFirst() }
        return String(word.prefix { !$0.isWhitespace })
    }

    public static func isValidCommand(_ command: String) -> Bool {
        let word = normalize(command)
        return !word.isEmpty && word.count <= 30
            && word.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// Имя навыка из слова команды: «отчёт» → `cmd-otchyot`.
    public static func skillName(for command: String) -> String {
        let latin = normalize(command)
            .applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? ""
        let slug = latin.lowercased()
            .map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
            .reduce(into: "") { result, char in
                if char == "-", result.last == "-" { return }
                result.append(char)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = slug.isEmpty ? "command" : String(slug.prefix(30))
        return "cmd-" + base
    }

    /// Описание навыка: по нему Claude решает, звать ли команду без «/».
    var skillDescription: String {
        var text = "Быстрая команда «\(title)». Используй, когда человек пишет /\(command)"
        let cleanPhrases = phrases.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !cleanPhrases.isEmpty {
            text += " или просит похожими словами: " + cleanPhrases.map { "«\($0)»" }.joined(separator: ", ")
        }
        return text + ". Также — если по смыслу человек просит то же самое."
    }

    /// Сообщение для агента. `/отчёт за август` → просьба выполнить команду, а текст
    /// после слова — уточнение. Без команды — `nil`.
    public static func expand(_ message: String, commands: [QuickCommand]) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let word = normalize(trimmed)
        guard let command = commands.first(where: { normalize($0.command) == word }) else { return nil }
        let rest = trimmed.dropFirst(1 + word.count).trimmingCharacters(in: .whitespacesAndNewlines)
        var text = "Выполни быструю команду «\(command.title)» — навык runie:\(command.name)."
        if !rest.isEmpty {
            text += "\nУточнение: \(rest)"
        }
        return text
    }

    /// Команды, подходящие к набранному «/отч».
    public static func matching(_ draft: String, in commands: [QuickCommand]) -> [QuickCommand] {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/"), !trimmed.dropFirst().contains(" ") else { return [] }
        let prefix = normalize(trimmed)
        return commands
            .filter { prefix.isEmpty || normalize($0.command).hasPrefix(prefix) || $0.title.lowercased().contains(prefix) }
            .sorted { normalize($0.command) < normalize($1.command) }
    }
}

extension RuniePlugin {

    private var commandsURL: URL { root.appendingPathComponent("runie-commands.json") }

    public func commands() -> [QuickCommand] {
        guard let data = try? Data(contentsOf: commandsURL),
              let commands = try? JSONDecoder().decode([QuickCommand].self, from: data) else { return [] }
        return commands.sorted { QuickCommand.normalize($0.command) < QuickCommand.normalize($1.command) }
    }

    /// Сохраняет команду. `replacing` — прежнее имя навыка, если команду переименовали.
    /// Возвращает сохранённую команду с именем навыка.
    @discardableResult
    public func saveCommand(_ command: QuickCommand, replacing previous: String? = nil) throws -> QuickCommand {
        var command = command
        command.command = QuickCommand.normalize(command.command)
        command.title = command.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.title.isEmpty else { throw Failure.badServer("Команде нужно название.") }
        guard QuickCommand.isValidCommand(command.command) else {
            throw Failure.badServer("Команда — одно слово из букв и цифр, например «отчёт».")
        }
        guard !command.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.badServer("Напишите, что делать по этой команде.")
        }
        var others = commands().filter { $0.name != previous && $0.name != command.name }
        if others.contains(where: { QuickCommand.normalize($0.command) == command.command }) {
            throw Failure.badServer("Команда /\(command.command) уже есть.")
        }

        let desired = QuickCommand.skillName(for: command.command)
        if command.name.isEmpty || command.name != desired {
            // Имя навыка следует за словом команды; занятое другим навыком — с номером.
            let taken = Set(others.map(\.name) + customSkills().map(\.name).filter { $0 != previous })
            var candidate = desired
            var index = 2
            while taken.contains(candidate) {
                candidate = "\(desired)-\(index)"
                index += 1
            }
            command.name = candidate
        }

        if let previous, previous != command.name {
            try? removeSkill(named: previous)
        }
        try saveSkill(Skill(name: command.name, description: command.skillDescription, instructions: command.instructions))
        others.append(command)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(others).write(to: commandsURL, options: .atomic)
        return command
    }

    public func removeCommand(named name: String) throws {
        let remaining = commands().filter { $0.name != name }
        try? removeSkill(named: name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(remaining).write(to: commandsURL, options: .atomic)
    }
}
