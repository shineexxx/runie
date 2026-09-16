import RunieKit
import SwiftUI

/// Кнопка у края — это орб Руни. Его настроение следует за агентом; задвинутый
/// за край, шар сдвигается к видимой полоске.
struct EdgeButtonView: View {

    let state: EdgeButtonState
    let session: ChatSession

    var body: some View {
        RunieOrb(mood: mood)
            .offset(x: tuckOffset)
            .scaleEffect(state.isPressed && !state.isDragging ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: state.isPressed)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: state.isTucked)
            .frame(width: EdgeButtonController.panelSize.width, height: EdgeButtonController.panelSize.height)
            .help(session.isBusy ? "Руни работает" : "Руни")
            .accessibilityElement()
            .accessibilityLabel("Руни")
            .accessibilityValue(accessibilityStatus)
            .accessibilityHint(state.isTucked ? "Выдвинуть" : "Открыть чат")
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

    /// Задвинутый шар прижимается к видимой полоске, чтобы из-за края торчал свет,
    /// а не пустое стекло.
    private var tuckOffset: CGFloat {
        guard state.isTucked, !state.isDragging else { return 0 }
        let inset = EdgeButtonController.orbInset
        return state.edge == .right ? -inset : inset
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
