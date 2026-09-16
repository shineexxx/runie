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
        case usage
        case general

        /// Вкладка настроек, а не раздел боковой панели.
        var isSettings: Bool { self != .history }
    }

    private var window: NSWindow?
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
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Runie"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 480)
        window.setFrameAutosaveName("RunieMainWindow")
        if !window.setFrameUsingName("RunieMainWindow") { window.center() }
        window.delegate = self
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
        NSApp.setActivationPolicy(.accessory)
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
