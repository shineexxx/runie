import Foundation

/// Что предлагать, когда человек набирает «/».
///
/// Раньше через «/» искались только быстрые команды, а навыки вызывались
/// обычными словами — и это было неочевидно: набрав «/тел», человек видел
/// пустоту, хотя навык для Телеграма есть. Теперь в одном списке и то, и
/// другое: сначала свои команды, потом навыки.
public struct SlashSuggestion: Identifiable, Equatable, Sendable {

    public enum Kind: Equatable, Sendable {
        /// Быстрая команда из настроек.
        case command
        /// Навык — свой, встроенный в Руни или из Claude Code.
        case skill
    }

    public let kind: Kind
    /// Как называется в поле после «/».
    public let slug: String
    /// Что показать человеку рядом: название команды или описание навыка.
    public let title: String
    /// Полное имя навыка для агента, например `runie:connect-telegram`.
    public let fullName: String

    public var id: String { "\(kind == .command ? "c" : "s"):\(fullName)" }
    /// Текст, который подставляется в поле ввода.
    public var draft: String { "/\(slug) " }

    public init(kind: Kind, slug: String, title: String, fullName: String) {
        self.kind = kind
        self.slug = slug
        self.title = title
        self.fullName = fullName
    }

    public init(_ command: QuickCommand) {
        self.init(kind: .command, slug: command.command, title: command.title, fullName: command.command)
    }

    public init(_ skill: SkillInfo) {
        let slug = Self.slug(ofSkill: skill.name)
        self.init(
            kind: .skill,
            slug: slug,
            title: Self.shorten(skill.description) ?? skill.name,
            fullName: skill.name
        )
    }

    /// `runie:connect-telegram` → `connect-telegram`: в поле человек пишет короткое.
    static func slug(ofSkill name: String) -> String {
        name.contains(":") ? String(name.split(separator: ":").last ?? "") : name
    }

    /// Первая фраза описания: в строку подсказки помещается только она.
    static func shorten(_ description: String?, limit: Int = 80) -> String? {
        guard let description, !description.isEmpty else { return nil }
        let sentence = description.split(whereSeparator: { $0 == "." || $0 == "\n" }).first.map(String.init) ?? description
        let trimmed = sentence.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > limit else { return trimmed }
        let cut = trimmed.prefix(limit)
        let lastSpace = cut.lastIndex(of: " ") ?? cut.endIndex
        return String(cut[..<lastSpace]) + "…"
    }

    /// Подсказки под набранное. Пустой «/» показывает всё, что есть.
    public static func matching(
        _ draft: String,
        commands: [QuickCommand],
        skills: [SkillInfo],
        disabledSkills: Set<String> = []
    ) -> [SlashSuggestion] {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/"), !trimmed.dropFirst().contains(" ") else { return [] }
        let prefix = QuickCommand.normalize(trimmed)

        let fromCommands = QuickCommand.matching(draft, in: commands).map(SlashSuggestion.init)
        let taken = Set(fromCommands.map(\.slug))
        let fromSkills = skills
            .filter { !disabledSkills.contains($0.name) }
            .map(SlashSuggestion.init)
            // Своя команда с тем же словом важнее: её человек завёл руками.
            .filter { !taken.contains($0.slug) }
            .filter { suggestion in
                guard !prefix.isEmpty else { return true }
                return suggestion.slug.lowercased().hasPrefix(prefix)
                    || suggestion.title.lowercased().contains(prefix)
                    || suggestion.fullName.lowercased().contains(prefix)
            }
            .sorted { $0.slug < $1.slug }
        return fromCommands + fromSkills
    }

    /// Разворачивает «/навык остаток» в просьбу к агенту. Быстрые команды
    /// разворачивает `QuickCommand.expand`, здесь — навыки. `nil` — не наше.
    public static func expand(_ text: String, commands: [QuickCommand], skills: [SkillInfo]) -> String? {
        // Своя команда важнее: её человек завёл руками.
        if let expanded = QuickCommand.expand(text, commands: commands) { return expanded }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.dropFirst()
        let slug = String(body.prefix(while: { !$0.isWhitespace })).lowercased()
        let rest = body.drop(while: { !$0.isWhitespace }).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty,
              let skill = skills.first(where: { self.slug(ofSkill: $0.name).lowercased() == slug })
        else { return nil }
        var request = t("Выполни навык \(skill.name).")
        if !rest.isEmpty {
            request += "\n" + t("Уточнение: \(rest)")
        }
        return request
    }
}
