import AppKit
import Observation
import RunieKit
import SwiftUI

/// Состояние кнопки, которое рисует SwiftUI.
@MainActor
@Observable
final class EdgeButtonState {
    enum Edge: String {
        case left
        case right
    }

    var edge: Edge = .right
    var isTucked = false
    var isPressed = false
    var isDragging = false
}

/// Плавающая кнопка у края экрана.
///
/// Тянется в любое место, при отпускании прилипает к ближайшему левому или правому
/// краю. Если отпустить у самой кромки экрана, кнопка задвигается за край и из-за
/// него торчит узкая полоска; клик по полоске выдвигает её обратно.
///
/// Мышь обрабатывается в AppKit, а не жестами SwiftUI: панель едет под курсором,
/// и локальные координаты жеста при этом скачут. Положение считается в экранных
/// координатах, пересчитанных из самого события через текущую рамку окна.
/// `NSEvent.mouseLocation` для этого не годится: это системный курсор, и для событий,
/// пришедших не от живой мыши (Accessibility, автоматизация), он стоит на месте.
@MainActor
final class EdgeButtonController {

    /// Панель больше самого шара (48): вокруг нужно место для свечения, иначе оно
    /// обрезается границей окна и вокруг орба проступает квадрат.
    static let panelSize = NSSize(width: 112, height: 112)
    /// Диаметр самого орба внутри панели.
    static let orbDiameter: CGFloat = 48
    /// Прозрачное поле между орбом и краем панели. Свечение и волнующийся край
    /// капли должны помещаться в него целиком, иначе край окна режет их по квадрату.
    static var orbInset: CGFloat { (panelSize.width - orbDiameter) / 2 }
    /// Отступ панели от края видимой области. Отрицательный: прозрачное поле
    /// вокруг шара и так отодвигает его от края.
    private static let margin: CGFloat = 8 - orbInset
    /// Сколько задвинутой панели торчит из-за края. Шар при этом прижат к полоске.
    private static let sliver: CGFloat = 22
    /// Смещение курсора, после которого нажатие считается перетаскиванием, а не кликом.
    private static let dragThreshold: CGFloat = 4
    /// Отпустить ближе этого к кромке экрана — значит задвинуть.
    private static let tuckZone: CGFloat = 10

    private enum DefaultsKey {
        static let edge = "edgeButton.edge"
        static let verticalPosition = "edgeButton.verticalPosition"
        static let tucked = "edgeButton.tucked"
    }

    let state = EdgeButtonState()
    let panel: FloatingPanel

    var onClick: (() -> Void)?
    /// Кнопка сдвинулась: чату надо переехать вслед.
    var onMove: (() -> Void)?
    var makeMenu: (() -> NSMenu)?

    /// Положение по вертикали как доля видимой высоты экрана, от 0 внизу до 1 вверху.
    private var verticalPosition: CGFloat
    private var pressLocation: NSPoint?
    private var grabOffset: NSSize = .zero

    init(session: ChatSession, chatLayout: ChatLayout) {
        let defaults = UserDefaults.standard
        state.edge = EdgeButtonState.Edge(rawValue: defaults.string(forKey: DefaultsKey.edge) ?? "") ?? .right
        state.isTucked = defaults.bool(forKey: DefaultsKey.tucked)
        let stored = defaults.object(forKey: DefaultsKey.verticalPosition) as? Double
        verticalPosition = CGFloat(stored ?? 0.5)

        panel = FloatingPanel(size: Self.panelSize, allowsKey: false)
        // Уровнем выше чата: орб лежит в конце поля ввода, поверх него.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        // Кнопка не уезжает в Mission Control вместе с окнами.
        panel.collectionBehavior.insert(.stationary)

        let hosting = EdgeButtonHostingView(rootView: EdgeButtonView(state: state, session: session, chatLayout: chatLayout))
        hosting.controller = self
        hosting.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = hosting

        layout(animated: false)
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout(animated: false) }
        }
    }

    var isTucked: Bool { state.isTucked }

    func setTucked(_ tucked: Bool) {
        state.isTucked = tucked
        save()
        layout(animated: true)
    }

    // MARK: - Мышь

    fileprivate func mouseDown(at location: NSPoint) {
        pressLocation = location
        grabOffset = NSSize(
            width: location.x - panel.frame.minX,
            height: location.y - panel.frame.minY
        )
        state.isPressed = true
    }

    fileprivate func mouseDragged(to location: NSPoint) {
        guard let pressLocation else { return }

        if !state.isDragging {
            let distance = hypot(location.x - pressLocation.x, location.y - pressLocation.y)
            guard distance >= Self.dragThreshold else { return }
            state.isDragging = true
            state.isTucked = false
        }

        panel.setFrameOrigin(NSPoint(
            x: location.x - grabOffset.width,
            y: location.y - grabOffset.height
        ))
        onMove?()
    }

    fileprivate func mouseUp(at location: NSPoint) {
        defer {
            pressLocation = nil
            state.isPressed = false
            state.isDragging = false
        }

        guard state.isDragging else {
            if state.isTucked {
                setTucked(false)
            } else {
                onClick?()
            }
            return
        }

        let screen = NSScreen.screens.first { $0.frame.contains(location) } ?? currentScreen
        let frame = screen.frame
        let visible = screen.visibleFrame

        state.edge = location.x < frame.midX ? .left : .right
        state.isTucked = location.x <= frame.minX + Self.tuckZone
            || location.x >= frame.maxX - Self.tuckZone

        let travel = max(visible.height - Self.panelSize.height, 1)
        verticalPosition = min(max((panel.frame.minY - visible.minY) / travel, 0), 1)

        save()
        layout(animated: true, on: screen)
    }

    fileprivate func menu() -> NSMenu? {
        makeMenu?()
    }

    // MARK: - Геометрия

    private var currentScreen: NSScreen {
        panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func layout(animated: Bool, on screen: NSScreen? = nil) {
        let target = frame(on: screen ?? currentScreen)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                panel.animator().setFrame(target, display: true)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.onMove?() }
            }
        } else {
            panel.setFrame(target, display: true)
            onMove?()
        }
    }

    private func frame(on screen: NSScreen) -> NSRect {
        let size = Self.panelSize
        let full = screen.frame
        let visible = screen.visibleFrame

        let x: CGFloat
        switch (state.edge, state.isTucked) {
        case (.right, false): x = visible.maxX - size.width - Self.margin
        case (.left, false): x = visible.minX + Self.margin
        // Задвигаем относительно настоящей кромки экрана, а не видимой области:
        // иначе полоска повиснет в воздухе рядом с Dock.
        case (.right, true): x = full.maxX - Self.sliver
        case (.left, true): x = full.minX - size.width + Self.sliver
        }

        let travel = max(visible.height - size.height, 0)
        let y = visible.minY + travel * verticalPosition
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(state.edge.rawValue, forKey: DefaultsKey.edge)
        defaults.set(state.isTucked, forKey: DefaultsKey.tucked)
        defaults.set(Double(verticalPosition), forKey: DefaultsKey.verticalPosition)
    }
}

/// Принимает мышь целиком на себя. SwiftUI внутри только рисует.
final class EdgeButtonHostingView: NSHostingView<EdgeButtonView> {

    weak var controller: EdgeButtonController?

    required init(rootView: EdgeButtonView) {
        super.init(rootView: rootView)
    }

    required init?(coder: NSCoder) {
        fatalError("не используется")
    }

    // Первый же клик по неактивной панели должен сработать, а не просто сфокусировать её.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Внутренние вьюхи SwiftUI не должны перехватывать события у контроллера.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { controller?.mouseDown(at: screenPoint(of: event)) }
    override func mouseDragged(with event: NSEvent) { controller?.mouseDragged(to: screenPoint(of: event)) }
    override func mouseUp(with event: NSEvent) { controller?.mouseUp(at: screenPoint(of: event)) }

    /// Точка события в экранных координатах по рамке окна на момент события.
    private func screenPoint(of event: NSEvent) -> NSPoint {
        guard let window = event.window ?? self.window else { return NSEvent.mouseLocation }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        controller?.menu()
    }
}
