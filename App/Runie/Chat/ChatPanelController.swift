import AppKit
import Observation
import RunieKit
import SwiftUI

/// Сигнал для чата: «поставь фокус в поле ввода». Панель переиспользуется, поэтому
/// `onAppear` срабатывает один раз, а показывать её можно сколько угодно.
@MainActor
@Observable
final class ChatFocusRequest {
    private(set) var generation = 0

    func request() {
        generation += 1
    }
}

/// Стеклянный чат, выезжающий рядом с кнопкой.
@MainActor
final class ChatPanelController {

    static let size = NSSize(width: 380, height: 560)
    /// Зазор между кнопкой и чатом.
    private static let gap: CGFloat = 4
    private static let screenInset: CGFloat = 8

    let panel: FloatingPanel
    private let focus = ChatFocusRequest()
    /// Меняется при каждом показе и скрытии. Анимация скрытия убирает панель, только
    /// если за время анимации её не открыли снова.
    private var visibilityGeneration = 0
    private var isHiding = false

    init(session: ChatSession) {
        panel = FloatingPanel(size: Self.size, allowsKey: true)

        let hosting = NSHostingView(rootView: ChatView(
            session: session,
            focus: focus,
            onClose: { [weak self] in self?.hide() }
        ))
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = hosting
        panel.onCancel = { [weak self] in self?.hide() }
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
            focus.request()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
            return
        }

        guard !panel.isVisible else {
            panel.setFrame(target, display: true)
            panel.makeKey()
            focus.request()
            return
        }

        panel.setFrame(target, display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        focus.request()

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
            }
        }
    }

    func follow(anchor: NSRect) {
        guard isVisible else { return }
        panel.setFrame(frame(anchor: anchor), display: true)
    }

    /// Чат открывается в сторону центра экрана от кнопки и не вылезает за экран.
    private func frame(anchor: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let size = Self.size
        let opensLeft = anchor.midX > screen.frame.midX

        var x = opensLeft ? anchor.minX - size.width - Self.gap : anchor.maxX + Self.gap
        var y = anchor.midY - size.height / 2

        x = min(max(x, visible.minX + Self.screenInset), visible.maxX - size.width - Self.screenInset)
        y = min(max(y, visible.minY + Self.screenInset), visible.maxY - size.height - Self.screenInset)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
