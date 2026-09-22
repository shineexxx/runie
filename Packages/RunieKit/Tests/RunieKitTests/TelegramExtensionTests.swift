import Foundation
import Testing
@testable import RunieKit

/// Навык подключения Телеграма: по нему Руни ведёт человека через BotFather и
/// объясняет, что тот делает сам. Разбор сообщений проверяется в `TelegramTests`.
@Suite("Навык Телеграма")
struct TelegramSkillTests {

    @Test("навык на месте и объясняет требования")
    func skill() throws {
        let plugin = RuniePlugin(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("runie-telegram-\(UUID().uuidString)"))
        try plugin.prepare()

        let skill = try #require(BundledSkills.all.first { $0.name == "connect-telegram" })
        #expect(skill.isBuiltIn)
        let file = try String(
            contentsOf: plugin.skillsURL.appendingPathComponent("connect-telegram/SKILL.md"),
            encoding: .utf8
        )
        let description = SkillCatalog.frontmatter(file)["description"] ?? ""
        #expect(description.contains("подключи телеграм"))
        // Premium — жёсткое условие: без него подключение невозможно, и человек
        // должен узнать об этом первым делом.
        #expect(skill.instructions.contains("Telegram Premium"))
        #expect(skill.instructions.contains("Business Mode"))
        // Отправка только с согласия — главное правило расширения.
        #expect(skill.instructions.contains("только после явного согласия человека"))
        // Подключение идёт через инструмент, а не через правку файлов руками.
        #expect(skill.instructions.contains("telegram_connect"))
    }
}
