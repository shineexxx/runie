import Foundation
import Testing
@testable import RunieKit

@Suite("Подсказки по «/»")
struct SlashSuggestionTests {

    private let commands = [
        QuickCommand(title: "Недельный отчёт", command: "отчёт", instructions: "1. Собери"),
        QuickCommand(title: "Сжать фото", command: "фото", instructions: "1. Сожми")
    ]
    private let skills = [
        SkillInfo(name: "runie:connect-telegram",
                  description: "Подключить Телеграм человека, чтобы читать его личную переписку. Используй, когда…",
                  path: nil, source: "runie"),
        SkillInfo(name: "runie:create-skill", description: "Сохранить новый навык Руни.", path: nil, source: "runie"),
        SkillInfo(name: "my-notes", description: "Заметки по проекту", path: nil, source: "Мои навыки")
    ]

    @Test("«/» показывает и команды, и навыки: команды первыми")
    func all() {
        let matches = SlashSuggestion.matching("/", commands: commands, skills: skills)
        #expect(matches.map(\.slug).prefix(2) == ["отчёт", "фото"])
        #expect(matches.map(\.slug).contains("connect-telegram"))
        #expect(matches.first?.kind == .command)
        #expect(matches.last?.kind == .skill)
    }

    @Test("навык находится и по имени, и по словам описания")
    func findSkill() {
        // То, с чего всё началось: «/conn» не подсказывал ничего.
        let byName = SlashSuggestion.matching("/conn", commands: commands, skills: skills)
        #expect(byName.map(\.slug) == ["connect-telegram", "create-skill"].filter { $0.hasPrefix("conn") })
        #expect(byName.first?.slug == "connect-telegram")
        // И по-русски, потому что описание навыка написано по-русски.
        let byWord = SlashSuggestion.matching("/телеграм", commands: commands, skills: skills)
        #expect(byWord.map(\.slug) == ["connect-telegram"])
        #expect(SlashSuggestion.matching("/велосипед", commands: commands, skills: skills).isEmpty)
    }

    @Test("подпись навыка — первая фраза описания, не длиннее строки")
    func title() {
        let telegram = SlashSuggestion.matching("/conn", commands: commands, skills: skills).first
        #expect(telegram?.title.hasPrefix("Подключить Телеграм") == true)
        #expect(!(telegram?.title.contains("Используй, когда") ?? true))
        #expect((telegram?.title.count ?? 0) <= 81)
    }

    @Test("выключенные навыки не предлагаются")
    func disabled() {
        let matches = SlashSuggestion.matching("/", commands: commands, skills: skills,
                                               disabledSkills: ["runie:connect-telegram"])
        #expect(!matches.map(\.slug).contains("connect-telegram"))
    }

    @Test("своя команда важнее навыка с тем же словом")
    func commandWins() {
        let same = [QuickCommand(title: "Свой телеграм", command: "connect-telegram", instructions: "x")]
        let matches = SlashSuggestion.matching("/connect-telegram", commands: same, skills: skills)
        #expect(matches.count == 1)
        #expect(matches.first?.kind == .command)
    }

    @Test("«/навык» разворачивается в просьбу к агенту")
    func expand() {
        let expanded = SlashSuggestion.expand("/connect-telegram", commands: commands, skills: skills)
        #expect(expanded == "Выполни навык runie:connect-telegram.")
        let withRest = SlashSuggestion.expand("/my-notes про RUN365", commands: commands, skills: skills)
        #expect(withRest == "Выполни навык my-notes.\nУточнение: про RUN365")
        // Быстрая команда по-прежнему разворачивается по-своему.
        #expect(SlashSuggestion.expand("/отчёт", commands: commands, skills: skills)?.contains("быструю команду") == true)
        // Обычный текст и чужой слэш не трогаем.
        #expect(SlashSuggestion.expand("привет", commands: commands, skills: skills) == nil)
        #expect(SlashSuggestion.expand("/usr/bin/python3", commands: commands, skills: skills) == nil)
    }

    @Test("вопрос человеку не требует разрешения")
    func askIsAlwaysAllowed() {
        #expect(PermissionClassifier.categories(toolName: "mcp__runie__ask_user", input: .object([:])).isEmpty)
        #expect(PermissionClassifier.categories(toolName: "AskUserQuestion", input: .object([:])).isEmpty)
        let request = PermissionRequest(requestID: "1", toolUseID: nil, toolName: "mcp__runie__ask_user",
                                        input: .object([:]), reason: nil)
        #expect(PermissionPolicy().allows(request))
    }
}
