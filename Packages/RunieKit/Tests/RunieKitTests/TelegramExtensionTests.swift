import Foundation
import Testing
@testable import RunieKit

/// Телеграм-расширение едет внутри приложения: код сервера лежит в ресурсах
/// RunieKit, а плагин раскладывает его у себя при каждом запуске. Сам разбор
/// сообщений проверяется отдельно — `Extensions/Telegram/test-telegram.py`.
@Suite("Телеграм-расширение")
struct TelegramExtensionTests {

    private func makePlugin() throws -> RuniePlugin {
        let plugin = RuniePlugin(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("runie-telegram-\(UUID().uuidString)"))
        try plugin.prepare()
        return plugin
    }

    @Test("код сервера кладётся в плагин и обновляется вместе с приложением")
    func serverCode() throws {
        let plugin = try makePlugin()
        let script = plugin.serversURL.appendingPathComponent("telegram.py")
        let body = try String(contentsOf: script, encoding: .utf8)
        #expect(body.hasPrefix("#!/usr/bin/env python3"))
        #expect(body.contains("business_connection"))
        #expect(body.contains("def mcp()"))

        // Повторная подготовка не трогает файл: он может быть запущен прямо сейчас.
        let before = try FileManager.default.attributesOfItem(atPath: script.path)[.modificationDate] as? Date
        try plugin.prepare()
        let after = try FileManager.default.attributesOfItem(atPath: script.path)[.modificationDate] as? Date
        #expect(before == after)

        // Чужие правки перетираются: код должен соответствовать версии приложения.
        try Data("сломали".utf8).write(to: script)
        try plugin.prepare()
        #expect(try String(contentsOf: script, encoding: .utf8).hasPrefix("#!/usr/bin/env python3"))
    }

    @Test("выключено у нового человека: ни службы, ни сервера")
    func offByDefault() throws {
        let plugin = try makePlugin()
        // Сервер не подключён — выключатель ничего не запускает и не роняет.
        #expect(plugin.servers().isEmpty)
        #expect(TelegramExtension.setEnabled(true, plugin: plugin) == nil)
        #expect(TelegramExtension.setEnabled(false, plugin: plugin) == nil)
        #expect(TelegramExtension.matches("telegram"))
        #expect(TelegramExtension.matches("plugin:runie:telegram"))
        #expect(!TelegramExtension.matches("telegraph"))
        #expect(!TelegramExtension.matches("notion"))
    }

    @Test("навык подключения на месте и объясняет требования")
    func skill() throws {
        let plugin = try makePlugin()
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
        // Отправка только с согласия — это главное правило расширения.
        #expect(skill.instructions.contains("только после явного согласия человека"))
        #expect(skill.instructions.contains("{root}/servers/telegram.py"))
    }
}
