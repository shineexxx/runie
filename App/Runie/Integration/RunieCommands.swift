import AppKit
import Foundation

/// Команды Руни снаружи: из Spotlight, Быстрых команд, Raycast.
///
/// Всё сходится сюда, чтобы и App Intents, и ссылки `runie://` вели себя
/// одинаково. Сами действия делает делегат приложения — он и подставляет их.
@MainActor
enum RunieCommands {

    /// Открыть чат и задать вопрос. `send` — отправить сразу или оставить в поле.
    static var ask: ((_ text: String, _ send: Bool) -> Void)?
    static var openChat: (() -> Void)?
    static var newConversation: (() -> Void)?

    /// Когда пришла последняя команда снаружи.
    ///
    /// Spotlight, запуская действие, «будит» приложение так же, как клик по
    /// значку в Dock, — и Руни открывал бы главное окно поверх чата. По этой
    /// отметке делегат понимает, что это не человек тянется к окну.
    static var lastCommand: Date?

    static func noteCommand() { lastCommand = Date() }

    /// Была ли команда снаружи рядом с этим моментом — до или после.
    static func isNearCommand(_ moment: Date, within seconds: TimeInterval = 3) -> Bool {
        guard let lastCommand else { return false }
        return abs(lastCommand.timeIntervalSince(moment)) < seconds
    }

    /// Приложения, которым можно отправлять вопрос без подтверждения.
    ///
    /// Ссылку `runie://` может открыть любой сайт, и вопрос от него — это чужие
    /// слова от имени человека. Поэтому от всех, кроме этого списка, вопрос
    /// только подставляется в поле: отправит его сам человек.
    static let trustedSenders: Set<String> = ["com.raycast.macos"]

    /// Разбирает ссылку `runie://…` и выполняет команду.
    ///
    ///     runie://ask?q=текст — спросить
    ///     runie://open        — открыть чат
    ///     runie://new         — новый разговор
    static func handle(_ url: URL, sender: String?) {
        guard url.scheme?.lowercased() == "runie" else { return }
        noteCommand()
        let command = (url.host() ?? url.path()).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "q" || $0.name == "text" }?.value ?? ""

        switch command {
        case "ask":
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                openChat?()
                return
            }
            ask?(text, sender.map(trustedSenders.contains) ?? false)
        case "new":
            newConversation?()
        default:
            openChat?()
        }
    }

    /// Кто открыл ссылку: приложение, приславшее событие «открыть адрес».
    static func currentSender() -> String? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let descriptor = event.attributeDescriptor(forKeyword: keySenderPIDAttr) else { return nil }
        let pid = pid_t(descriptor.int32Value)
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }
}
