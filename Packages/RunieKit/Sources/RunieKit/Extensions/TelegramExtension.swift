import Foundation

/// Выключатель телеграм-расширения.
///
/// У расширения есть вторая половина, которой нет у обычных MCP-серверов:
/// фоновая служба, собирающая переписку, пока компьютер включён. Выключатель в
/// «Навыках» должен останавливать именно её, а не просто прятать инструменты —
/// иначе выключенное расширение продолжало бы читать сообщения.
///
/// У нового человека всё выключено: службы нет, пока он не попросит подключить
/// Телеграм, и она не заводится сама.
public enum TelegramExtension {

    public static let serverName = "telegram"

    /// Про этот ли сервер речь. Claude Code зовёт серверы плагина полным именем
    /// вида `plugin:runie:telegram`, а настройки могут хранить короткое.
    public static func matches(_ name: String) -> Bool {
        name == serverName || name.hasSuffix(":\(serverName)")
    }

    /// Включает или выключает сбор переписки. Возвращает, что ответил скрипт.
    ///
    /// Пока человек не подключил Телеграм, делать нечего: код сервера лежит в
    /// плагине всегда, но службы без подключения не существует.
    @discardableResult
    public static func setEnabled(_ enabled: Bool, plugin: RuniePlugin = .standard) -> String? {
        guard plugin.servers().contains(where: { $0.name == serverName }) else { return nil }
        // Выключенное расширение не поднимаем обратно без нужды.
        guard enabled != isCollecting() else { return nil }
        return run([enabled ? "enable" : "disable"], plugin: plugin)
    }

    private static func run(_ arguments: [String], plugin: RuniePlugin) -> String? {
        let script = plugin.serversURL.appendingPathComponent("\(serverName).py")
        guard FileManager.default.fileExists(atPath: script.path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Убирает службу, ключ бота и всю накопленную переписку.
    @discardableResult
    public static func remove(plugin: RuniePlugin = .standard) -> String? {
        run(["remove"], plugin: plugin)
    }

    /// Собирается ли переписка прямо сейчас.
    public static func isCollecting() -> Bool {
        let agent = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/app.runie.telegram.plist")
        return FileManager.default.fileExists(atPath: agent.path)
    }
}
