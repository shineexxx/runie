import RunieKit
import SwiftUI

/// Кнопка у края — это орб Руни. Его настроение следует за агентом; задвинутый
/// за край, шар сдвигается к видимой полоске.
struct EdgeButtonView: View {

    let state: EdgeButtonState
    let session: ChatSession
    let chatLayout: ChatLayout

    var body: some View {
        RunieOrb(mood: mood, release: release, releaseDirection: releaseDirection, glyph: glyph)
            .offset(x: tuckOffset)
            .scaleEffect(state.isPressed && !state.isDragging ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: state.isPressed)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: state.isTucked)
            .frame(width: EdgeButtonController.panelSize.width, height: EdgeButtonController.panelSize.height)
            .help(session.isBusy ? "Руни работает" : "Руни")
            .accessibilityElement()
            .accessibilityLabel("Руни")
            .accessibilityValue(accessibilityStatus)
            .accessibilityHint(accessibilityHint)
    }

    private var mood: RunieMood {
        #if DEBUG
        // Для работы над внешним видом: `-RunieMood working` в аргументах запуска.
        if let forced = UserDefaults.standard.string(forKey: "RunieMood").flatMap(RunieMood.init(rawValue:)) {
            return forced
        }
        #endif
        return state.isDragging ? .carried : RunieMood(activity: session.timeline.activity)
    }

    /// Открытый чат забирает свет из орба: из него и вытекает интерфейс. Пока агент
    /// работает, свет возвращается — видно, что Руни занят.
    private var release: Double {
        chatLayout.isOpen && !session.isBusy ? 1 : 0
    }

    /// Свет уходит туда, где открывается чат, — к центру экрана.
    private var releaseDirection: Double {
        state.edge == .right ? -1 : 1
    }

    /// На тёмном ядре — то, что сделает клик по орбу.
    private var glyph: OrbGlyph {
        guard chatLayout.isOpen else { return .none }
        if session.isBusy { return .stop }
        return .send(enabled: chatLayout.hasDraft)
    }

    /// Задвинутый шар прижимается к видимой полоске, чтобы из-за края торчал свет,
    /// а не пустое стекло.
    private var tuckOffset: CGFloat {
        guard state.isTucked, !state.isDragging else { return 0 }
        let inset = EdgeButtonController.orbInset
        return state.edge == .right ? -inset : inset
    }

    /// Что сделает клик: орб — и вызов чата, и кнопка отправки, и стоп.
    private var accessibilityHint: String {
        if state.isTucked { return "Выдвинуть" }
        guard chatLayout.isOpen else { return "Открыть чат" }
        if session.isBusy { return "Остановить" }
        return chatLayout.hasDraft ? "Отправить" : "Закрыть чат"
    }

    private var accessibilityStatus: String {
        switch RunieMood(activity: session.timeline.activity) {
        case .idle, .carried: "свободен"
        case .thinking: "думает"
        case .working: "работает"
        case .responding: "отвечает"
        }
    }
}
