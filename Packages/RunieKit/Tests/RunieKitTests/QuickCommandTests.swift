import Foundation
import Testing
@testable import RunieKit

@Suite("Быстрые команды")
struct QuickCommandTests {

    private func makePlugin() throws -> RuniePlugin {
        let plugin = RuniePlugin(root: FileManager.default.temporaryDirectory.appendingPathComponent("runie-cmd-\(UUID().uuidString)"))
        try plugin.prepare()
        return plugin
    }

    @Test("слово команды и имя навыка")
    func names() {
        #expect(QuickCommand.normalize(" /Отчёт за месяц") == "отчёт")
        #expect(QuickCommand.skillName(for: "отчёт") == "cmd-otcet")
        #expect(QuickCommand.skillName(for: "tg-photo") == "cmd-tg-photo")
        #expect(RuniePlugin.isValidName(QuickCommand.skillName(for: "сжать фото!")))
        #expect(QuickCommand.isValidCommand("/сжать"))
        #expect(!QuickCommand.isValidCommand("/"))
        #expect(!QuickCommand.isValidCommand("а.б"))
    }

    @Test("сохранение пишет навык с описанием и фразами; переименование убирает старый")
    func save() throws {
        let plugin = try makePlugin()
        let saved = try plugin.saveCommand(.init(title: "Недельный отчёт", command: "/Отчёт",
                                                 phrases: ["итоги недели", " "], instructions: "1. Собери"))
        #expect(saved.command == "отчёт")
        let skill = try String(contentsOf: plugin.skillsURL.appendingPathComponent("\(saved.name)/SKILL.md"), encoding: .utf8)
        let description = SkillCatalog.frontmatter(skill)["description"] ?? ""
        #expect(description.contains("/отчёт"))
        #expect(description.contains("«итоги недели»"))
        #expect(plugin.commands() == [saved])

        var renamed = saved
        renamed.command = "итоги"
        let second = try plugin.saveCommand(renamed, replacing: saved.name)
        #expect(plugin.commands().map(\.command) == ["итоги"])
        #expect(!FileManager.default.fileExists(atPath: plugin.skillsURL.appendingPathComponent(saved.name).path))
        #expect(FileManager.default.fileExists(atPath: plugin.skillsURL.appendingPathComponent(second.name).path))

        try plugin.removeCommand(named: second.name)
        #expect(plugin.commands().isEmpty)
        #expect(plugin.customSkills().isEmpty)
    }

    @Test("проверки: пусто, повтор команды")
    func validation() throws {
        let plugin = try makePlugin()
        try plugin.saveCommand(.init(title: "А", command: "а", instructions: "x"))
        #expect(throws: RuniePlugin.Failure.self) { try plugin.saveCommand(.init(title: "Б", command: "/А", instructions: "y")) }
        #expect(throws: RuniePlugin.Failure.self) { try plugin.saveCommand(.init(title: "", command: "в", instructions: "y")) }
        #expect(throws: RuniePlugin.Failure.self) { try plugin.saveCommand(.init(title: "Г", command: "г", instructions: " ")) }
    }

    @Test("«/отчёт за август» разворачивается, чужое — нет; подсказки по началу")
    func expandAndMatch() {
        let commands = [
            QuickCommand(name: "cmd-otcet", title: "Недельный отчёт", command: "отчёт", instructions: ""),
            QuickCommand(name: "cmd-szat", title: "Сжать фото", command: "сжать", instructions: "")
        ]
        let expanded = QuickCommand.expand("/Отчёт за август", commands: commands)
        #expect(expanded?.contains("runie:cmd-otcet") == true)
        #expect(expanded?.contains("Уточнение: за август") == true)
        #expect(QuickCommand.expand("/неизвестно", commands: commands) == nil)
        #expect(QuickCommand.expand("отчёт", commands: commands) == nil)
        #expect(QuickCommand.matching("/", in: commands).count == 2)
        #expect(QuickCommand.matching("/сж", in: commands).map(\.command) == ["сжать"])
        #expect(QuickCommand.matching("/сжать фото", in: commands).isEmpty)
    }
}
