import RunieKit
import SwiftUI

/// Круглая стеклянная кнопка. Пока агент работает — знак медленно пульсирует,
/// чтобы было видно, что Runie занят, даже когда чат закрыт.
struct EdgeButtonView: View {

    let state: EdgeButtonState
    let session: ChatSession

    private static let diameter: CGFloat = 48

    var body: some View {
        ZStack {
            Image(systemName: "sparkle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
                .symbolEffect(.pulse, options: .repeating, isActive: session.isBusy)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .glassEffect(.regular.interactive(), in: .circle)
        .scaleEffect(scale)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: state.isPressed)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: state.isDragging)
        .frame(width: EdgeButtonController.panelSize.width, height: EdgeButtonController.panelSize.height)
        .help(session.isBusy ? "Runie работает" : "Runie")
        .accessibilityLabel("Runie")
        .accessibilityHint(state.isTucked ? "Выдвинуть кнопку" : "Открыть чат")
    }

    private var scale: CGFloat {
        if state.isDragging { return 1.08 }
        if state.isPressed { return 0.92 }
        return 1
    }
}
