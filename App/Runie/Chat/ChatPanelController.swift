import AppKit
import Observation
import RunieKit
import SwiftUI

/// Состояние раскладки чата, общее для контроллера и SwiftUI.
@MainActor
@Observable
final class ChatLayout {
    /// Вся переписка вместо одного последнего ответа.
    var isExpanded = false
    /// С какой стороны от блоков стоит орб: к нему блоки и прижимаются.
    var orbSide: HorizontalEdge = .trailing
    /// Сигнал «поставь фокус в поле ввода». Панель переиспользуется, поэтому
    /// `onAppear` срабатывает один раз, а показывать её можно сколько угодно.
    private(set) var focusGeneration = 0

    func requestFocus() {
        focusGeneration += 1
    }
}

/// Чат без подложки: отдельные стеклянные блоки рядом с орбом.
///
/// Окно прозрачное и заметно больше видимых блоков — в нём хватает места для
/// развёрнутой переписки. Блоки прижаты к низу окна, а окно выставлено так, чтобы
/// поле ввода стояло вровень с орбом, как у Eney.
@MainActor
final class ChatPanelController {

    /// Наибольший размер окна. Высота подстраивается под место над орбом.
    static let size = NSSize(width: 380 + shadowMargin * 2, height: 640)
    /// Прозрачное поле вокруг блоков. Тень блока выходит далеко за его край,
    /// и если поля не хватает, край окна обрезает её прямой линией.
    static let shadowMargin: CGFloat = 40
    /// Меньше этого окно не сжимается: иначе ответу негде поместиться.
    private static let minimumHeight: CGFloat = 320
    /// Высота ряда подсказок под полем ввода.
    static let chipsHeight: CGFloat = 36
    /// Высота поля ввода.
    static let inputHeight: CGFloat = 50
    static let blockSpacing: CGFloat = 10
    static var bottomInset: CGFloat { shadowMargin }
    /// Зазор между орбом и блоками.
    private static let gap: CGFloat = 2
    private static let screenInset: CGFloat = 8

    /// Расстояние от низа окна до середины поля ввода — по нему окно
    /// выравнивается относительно орба.
    private static var inputCenterFromBottom: CGFloat {
        bottomInset + chipsHeight + blockSpacing + inputHeight / 2
    }

    let panel: FloatingPanel
    let layout = ChatLayout()

    /// Меняется при каждом показе и скрытии. Анимация скрытия убирает панель, только
    /// если за время анимации её не открыли снова.
    private var visibilityGeneration = 0
    private var isHiding = false

    init(session: ChatSession) {
        panel = FloatingPanel(size: Self.size, allowsKey: true)

        let hosting = NSHostingView(rootView: ChatView(
            session: session,
            layout: layout,
            onClose: { [weak self] in self?.hide() }
        ))
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.onCancel = { [weak self] in self?.cancel() }
    }

    /// Видим и не уезжает прямо сейчас.
    var isVisible: Bool { panel.isVisible && !isHiding }

    func toggle(anchor: NSRect) {
        isVisible ? hide() : show(anchor: anchor)
    }

    func show(anchor: NSRect) {
        visibilityGeneration += 1
        let target = frame(anchor: anchor)

        if isHiding {
            // Передумали закрывать: возвращаем прозрачность, панель ещё на экране.
            isHiding = false
            panel.setFrame(target, display: true)
            panel.makeKey()
            layout.requestFocus()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
            return
        }

        guard !panel.isVisible else {
            panel.setFrame(target, display: true)
            panel.makeKey()
            layout.requestFocus()
            return
        }

        panel.setFrame(target, display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        layout.requestFocus()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard isVisible else { return }
        visibilityGeneration += 1
        let generation = visibilityGeneration
        isHiding = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.visibilityGeneration else { return }
                self.isHiding = false
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                self.layout.isExpanded = false
            }
        }
    }

    func follow(anchor: NSRect) {
        guard isVisible else { return }
        panel.setFrame(frame(anchor: anchor), display: true)
    }

    /// Esc сначала сворачивает переписку, потом закрывает чат.
    private func cancel() {
        if layout.isExpanded {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                layout.isExpanded = false
            }
        } else {
            hide()
        }
    }

    /// Блоки открываются в сторону центра экрана от орба, поле ввода вровень с ним.
    private func frame(anchor: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let size = Self.size
        let orbOnRight = anchor.midX > screen.frame.midX
        layout.orbSide = orbOnRight ? .trailing : .leading

        // Зазор считаем от видимых краёв — шара и блоков, — а не от прозрачных полей
        // обоих окон.
        let orbInset = EdgeButtonController.orbInset
        var x = orbOnRight
            ? anchor.minX + orbInset - Self.gap + Self.shadowMargin - size.width
            : anchor.maxX - orbInset + Self.gap - Self.shadowMargin
        // Прозрачные поля окна могут заходить за край экрана — не должны только блоки.
        let edgeSlack = Self.shadowMargin - Self.screenInset
        x = min(max(x, visible.minX - edgeSlack), visible.maxX - size.width + edgeSlack)

        // Поле ввода вровень с орбом. Окно растёт вверх настолько, насколько позволяет
        // экран: если отвести ему всегда полную высоту, над орбом посередине экрана
        // оно не влезает, и ограничитель уводит поле ввода далеко вниз от шара.
        var y = max(anchor.midY - Self.inputCenterFromBottom, visible.minY - edgeSlack)
        var height = min(size.height, visible.maxY + edgeSlack - y)
        if height < Self.minimumHeight {
            height = Self.minimumHeight
            y = visible.maxY + edgeSlack - height
        }
        return NSRect(x: x, y: y, width: size.width, height: height)
    }
}
