import AppKit
import RunieKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var session: ChatSession!
    private var tracker: FrontmostAppTracker!
    private var button: EdgeButtonController!
    private var chat: ChatPanelController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Дублирует LSUIElement из Info.plist: без иконки в Dock и без строки меню.
        NSApp.setActivationPolicy(.accessory)

        session = ChatSession(backend: Self.makeBackend())
        tracker = FrontmostAppTracker()
        chat = ChatPanelController(session: session, tracker: tracker)
        button = EdgeButtonController(session: session, chatLayout: chat.layout)

        button.onClick = { [weak self] in
            self?.orbClicked()
        }
        button.onMove = { [weak self] in
            guard let self, chat != nil else { return }
            chat.follow(anchor: button.panel.frame)
        }
        button.makeMenu = { [weak self] in
            self?.makeButtonMenu() ?? NSMenu()
        }
    }

    /// Орб лежит в конце поля ввода и отвечает за всё сразу: открыть чат,
    /// отправить черновик, остановить агента, закрыть пустой чат.
    private func orbClicked() {
        guard chat.isVisible else {
            chat.show(anchor: button.panel.frame)
            return
        }
        if session.isBusy {
            session.stop()
        } else if chat.layout.hasDraft {
            chat.submitDraft()
        } else {
            chat.hide()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        session?.stop()
    }

    private func makeButtonMenu() -> NSMenu {
        let menu = NSMenu()

        if chat.isVisible {
            menu.addItem(ClosureMenuItem("Закрыть чат", symbol: "xmark") { [weak self] in
                self?.chat.hide()
            })
        } else {
            menu.addItem(ClosureMenuItem("Открыть чат", symbol: "bubble.left") { [weak self] in
                guard let self else { return }
                if button.isTucked { button.setTucked(false) }
                chat.show(anchor: button.panel.frame)
            })
        }

        if button.isTucked {
            menu.addItem(ClosureMenuItem("Выдвинуть кнопку", symbol: "arrow.left.and.right") { [weak self] in
                self?.button.setTucked(false)
            })
        } else {
            menu.addItem(ClosureMenuItem("Спрятать к краю", symbol: "arrow.right.to.line") { [weak self] in
                self?.chat.hide()
                self?.button.setTucked(true)
            })
        }

        menu.addItem(.separator())

        let startOver = ClosureMenuItem("Новый разговор", symbol: "square.and.pencil") { [weak self] in
            self?.session.startOver()
        }
        startOver.isEnabled = !session.timeline.items.isEmpty
        menu.autoenablesItems = false
        menu.addItem(startOver)

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Выйти из Runie") {
            NSApp.terminate(nil)
        })
        return menu
    }

    private static func makeBackend() -> any AgentBackend {
        do {
            let executable = try ClaudeCodeLocator().locate()
            // Агент работает от домашней папки: пользователь просит про свои файлы,
            // а не про какой-то проект.
            return ClaudeCodeBackend(
                executable: executable,
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser
            )
        } catch {
            return UnavailableBackend()
        }
    }
}

/// Бэкенд на случай, когда Claude Code не установлен. Приложение при этом
/// запускается нормально и объясняет, что делать, при первой же попытке написать.
struct UnavailableBackend: AgentBackend {

    struct NotInstalled: LocalizedError {
        var errorDescription: String? {
            "Claude Code не найден. Установите его и выполните в терминале `claude login`, затем перезапустите Runie."
        }
    }

    func connect(resuming sessionID: String?) throws -> AgentConnectionHandle {
        throw NotInstalled()
    }
}
