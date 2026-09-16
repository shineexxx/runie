import AppKit
import RunieKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var session: ChatSession!
    private var tracker: FrontmostAppTracker!
    private var button: EdgeButtonController!
    private var chat: ChatPanelController!
    private var settings: AppSettings!
    private var suggestions: SuggestionsModel!
    private var mainWindow: MainWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Дублирует LSUIElement из Info.plist: без иконки в Dock и без строки меню.
        NSApp.setActivationPolicy(.accessory)

        session = ChatSession(backend: Self.makeBackend())
        let store = ChatHistoryStore.standard()
        session.store = store
        settings = AppSettings()
        session.policy = settings.policy
        session.restoreModels(settings.cachedModels, selected: settings.selectedModel)
        session.onModelsUpdate = { [weak self] models in
            self?.settings.cachedModels = models
        }
        settings.onPolicyChange = { [weak self] policy in
            self?.session.policy = policy
        }
        mainWindow = MainWindowController(session: session, settings: settings, store: store)
        mainWindow.onContinue = { [weak self] record in
            guard let self else { return }
            if session.conversationID != record.id {
                session.open(record)
            }
            if !chat.isVisible { openChat() }
        }
        tracker = FrontmostAppTracker()
        suggestions = SuggestionsModel(store: store)
        chat = ChatPanelController(session: session, tracker: tracker, settings: settings, suggestions: suggestions)
        button = EdgeButtonController(session: session, chatLayout: chat.layout)
        // Агент стоит, пока человек не ответит: вопрос должен быть на виду.
        session.onPermissionRequest = { [weak self] in
            guard let self, !chat.isVisible, !mainWindow.isShowingCurrentConversation else { return }
            openChat()
        }
        // Кнопка масштабирования в чате: разговор целиком — в окне Runie.
        chat.onOpenWindow = { [weak self] in
            guard let self else { return }
            chat.hide()
            mainWindow.showConversation(session.conversationID)
        }
        chat.onHide = { [weak self] in
            self?.button.reattach()
        }

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

        #if DEBUG
        // Для съёмки анимаций: `-RunieAutoOpen 3` открывает чат через 3 секунды
        // после запуска. Клик инструментом автоматизации доходит с непредсказуемой
        // задержкой, и привязать к нему съёмку кадров нельзя.
        let autoOpen = UserDefaults.standard.double(forKey: "RunieAutoOpen")
        if autoOpen > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + autoOpen) { [weak self] in
                self?.orbClicked()
            }
        }
        if UserDefaults.standard.bool(forKey: "RunieOpenModelMenu"), autoOpen > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + autoOpen + 1.5) {
                NotificationCenter.default.post(name: .runieDebugOpenModelMenu, object: nil)
            }
        }
        // `-RunieOpenWindow permissions` открывает окно Runie на нужном разделе.
        if let section = UserDefaults.standard.string(forKey: "RunieOpenWindow") {
            mainWindow.show(MainWindowController.Section(rawValue: section))
        }
        // `-RunieAutoSend "текст"` вместе с `-RunieAutoOpen` отправляет сообщение после
        // открытия — чтобы проверять живые ходы агента без мыши.
        if let text = UserDefaults.standard.string(forKey: "RunieAutoSend"), autoOpen > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + autoOpen + 1) { [weak self] in
                self?.chat.send(text)
            }
        }
        #endif
    }

    /// Орб открывает и закрывает чат. Прицепленный к краю сначала отходит от кромки,
    /// чтобы чату было куда открыться, и только потом выпускает свет.
    private func orbClicked() {
        if chat.isVisible {
            chat.hide()
        } else {
            openChat()
        }
    }

    private func openChat() {
        // Агент поднимается, пока чат открывается: к первому сообщению список
        // моделей уже свежий, а ответ приходит быстрее.
        session.prepare()
        // Подсказки обновляются в фоне; чат открывается с последними готовыми.
        if session.timeline.items.isEmpty {
            suggestions.refresh(for: tracker.current?.context)
        }
        button.detach { [weak self] in
            guard let self else { return }
            chat.show(anchor: button.panel.frame)
        }
    }

    /// Клик по значку в Dock, пока открыто окно, — вернуть окно.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.show()
        return true
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
                self?.openChat()
            })
        }

        menu.addItem(ClosureMenuItem("Открыть Runie…", symbol: "macwindow") { [weak self] in
            self?.mainWindow.show()
        })
        menu.addItem(ClosureMenuItem("Разрешения…", symbol: "hand.raised") { [weak self] in
            self?.mainWindow.show(.permissions)
        })

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
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
                arguments: ClaudeCodeArguments(appendSystemPrompt: runiePrompt)
            )
        } catch {
            return UnavailableBackend()
        }
    }
}

/// Дописывается к системному промпту Claude Code.
///
/// Описание вызова инструмента человек видит в «руках» и в вопросе о разрешении —
/// по нему он решает, пускать ли агента. Поэтому описание по-русски и по-человечески.
private let runiePrompt = """
Ты работаешь внутри Runie — помощника на Mac. Пользователь не обязательно программист \
и видит не твои команды, а их краткие описания. Отвечай на языке пользователя. \
Поле description у инструментов (например, у Bash) пиши кратко по-русски, с глаголом \
в настоящем времени, например «Узнаёт версию macOS» или «Ищет файлы с отчётами»: \
по этому описанию пользователь решает, разрешить ли действие.
"""

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
