import AppKit
import RunieKit
import SwiftUI

/// Полноценное окно Runie: история разговоров, разрешения, подписка.
///
/// Пока окно открыто, у Runie есть значок в Dock и меню — как у обычного приложения,
/// иначе окно теряется за другими. Закрыли — Runie снова живёт только орбом.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {

    enum Section: String, Hashable, CaseIterable {
        case history
        case permissions
        case servers
        case skills
        case usage
        case general

        /// Вкладка настроек, а не раздел боковой панели.
        var isSettings: Bool { self != .history }
    }

    private var window: NSWindow?
    private var pasteMonitor: Any?
    private let session: ChatSession
    private let settings: AppSettings
    private let store: ChatHistoryStore
    private let navigation = MainNavigation()
    /// Продолжить разговор в чате у орба.
    var onContinue: ((ConversationRecord) -> Void)?

    init(session: ChatSession, settings: AppSettings, store: ChatHistoryStore) {
        self.session = session
        self.settings = settings
        self.store = store
    }

    /// Окно на экране и в нём открыт текущий разговор — вопросы агента видны здесь.
    var isShowingCurrentConversation: Bool {
        guard let window, window.isVisible, !window.isMiniaturized else { return false }
        return navigation.section == .history && navigation.selectedConversation == session.conversationID
    }

    /// Открывает окно на настройках — на той вкладке, где их закрыли.
    func showSettings() {
        show(navigation.lastSettingsTab)
    }

    /// Открывает окно на разговоре: он выделяется в истории.
    func showConversation(_ id: UUID) {
        navigation.selectedConversation = id
        show(.history)
    }

    func show(_ section: Section? = nil) {
        if let section { navigation.section = section }
        session.prepare()
        let window = self.window ?? makeWindow()
        self.window = window
        window.showInFront()
    }

    private func makeWindow() -> NSWindow {
        // `-RunieWindowSize 1440x900` — размер окна для снимков экрана.
        var size = NSSize(width: 980, height: 660)
        #if DEBUG
        if let forced = UserDefaults.standard.string(forKey: "RunieWindowSize") {
            let parts = forced.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { size = NSSize(width: parts[0], height: parts[1]) }
        }
        #endif
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Runie"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 480)
        var forcedSize = false
        #if DEBUG
        forcedSize = UserDefaults.standard.string(forKey: "RunieWindowSize") != nil
        #endif
        if forcedSize {
            // Заданный размер важнее запомненного: снимки должны быть одинаковыми.
            window.setContentSize(size)
            window.center()
        } else {
            window.setFrameAutosaveName("RunieMainWindow")
            if !window.setFrameUsingName("RunieMainWindow") { window.center() }
        }
        window.delegate = self
        // ⌘V с картинкой — во вложения разговора в окне.
        pasteMonitor = AttachmentStore.installPasteHandler(for: { [weak self] in self?.window }) { files in
            NotificationCenter.default.post(name: .runiePasteAttachments, object: nil, userInfo: ["files": files])
        }
        window.contentView = NSHostingView(rootView: MainWindowView(
            navigation: navigation,
            session: session,
            settings: settings,
            store: store,
            onContinue: { [weak self] record in self?.onContinue?(record) }
        ))
        return window
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.hideFromDockIfNoOrdinaryWindowsLeft(besides: notification.object as? NSWindow)
    }
}

@MainActor
@Observable
final class MainNavigation {
    var section: MainWindowController.Section = .history {
        didSet { if section.isSettings { lastSettingsTab = section } }
    }
    /// Настройки открываются на той вкладке, где их закрыли.
    var lastSettingsTab: MainWindowController.Section = .permissions
    /// Какой разговор выделить в истории.
    var selectedConversation: UUID?
}
