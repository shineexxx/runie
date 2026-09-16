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

    /// К какому краю экрана прицеплен орб. `nil` — свободно висит в нижней половине.
    var dock: Edge?
    /// Прицепленный орб отошёл от края, пока открыт чат.
    var isDetached = false
    var isPressed = false
    var isDragging = false
    /// Прицепленный орб, которого давно не трогали, ушёл за край: торчит только горбик.
    var isRetracted = false

    /// Держится за край тёмной перемычкой прямо сейчас.
    var isAttached: Bool { dock != nil && !isDetached && !isDragging }
}

/// Орб Руни — плавающая кнопка в нижней половине экрана.
///
/// Тянется куда угодно в нижней половине. Отпущенный у левого или правого края,
/// прицепляется к нему: встаёт вплотную и утопает в кромку, а край выпирает к нему чёрным горбом.
/// Клик по прицепленному орбу сначала отводит его от края и только потом открывает
/// чат; закрылся чат — орб возвращается к краю.
///
/// Мышь обрабатывается в AppKit, а не жестами SwiftUI: панель едет под курсором,
/// и локальные координаты жеста при этом скачут. Положение считается в экранных
/// координатах, пересчитанных из самого события через текущую рамку окна.
/// `NSEvent.mouseLocation` для этого не годится: это системный курсор, и для событий,
/// пришедших не от живой мыши (Accessibility, автоматизация), он стоит на месте.
@MainActor
final class EdgeButtonController {

    /// Панель больше самого шара (48): вокруг нужно место для свечения, иначе оно
    /// обрезается границей окна и вокруг орба проступает квадрат. По высоте ещё
    /// больше — в неё целиком с ореолом входит горб, которым край держит орб.
    nonisolated static let panelSize = NSSize(width: 112, height: 176)
    /// Диаметр самого орба внутри панели.
    nonisolated static let orbDiameter: CGFloat = 48
    /// Во сколько раз сжимается тёмное ядро, когда свет ушёл в чат.
    nonisolated static let openScale: CGFloat = 0.5
    /// От центра прицепленного орба до кромки экрана: шар наполовину утоплен в край.
    nonisolated static let attachedInset: CGFloat = 12
    /// Насколько отходит от края прицепленный орб, когда открывается чат.
    private static let detachedInset: CGFloat = 84
    /// Отпустить центр орба ближе этого к кромке — значит прицепить.
    private static let dockZone: CGFloat = 80
    /// Свободный орб не подходит к краю видимой области ближе этого.
    private static let freeInset: CGFloat = 40
    /// Нижняя граница центра орба над видимой областью. Ниже ряд подсказок под полем
    /// ввода уже не помещается, и поле перестаёт стоять вровень с орбом.
    private static let bottomLimit: CGFloat = 84
    /// Сколько прицепленный орб ждёт без курсора рядом, прежде чем уйти за край.
    private static let retractDelay: Duration = .seconds(3)
    /// Смещение курсора, после которого нажатие считается перетаскиванием, а не кликом.
    private static let dragThreshold: CGFloat = 4

    private enum DefaultsKey {
        static let dock = "orb.dock"
        static let x = "orb.x"
        static let y = "orb.y"
    }

    let state = EdgeButtonState()
    let panel: FloatingPanel

    var onClick: (() -> Void)?
    /// Кнопка сдвинулась: чату надо переехать вслед.
    var onMove: (() -> Void)?
    var makeMenu: (() -> NSMenu)?

    private let chatLayout: ChatLayout
    /// Центр свободного орба как доля видимой области экрана: x слева направо,
    /// y снизу вверх, не выше середины.
    private var position: CGPoint
    private var pressLocation: NSPoint?
    private var grabOffset: NSSize = .zero
    private var monitors: [Any] = []
    private var retractTask: Task<Void, Never>?

    init(session: ChatSession, chatLayout: ChatLayout) {
        self.chatLayout = chatLayout

        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: DefaultsKey.dock) {
            state.dock = EdgeButtonState.Edge(rawValue: stored)
        } else {
            state.dock = .right
        }
        position = CGPoint(
            x: (defaults.object(forKey: DefaultsKey.x) as? Double) ?? 0.5,
            y: (defaults.object(forKey: DefaultsKey.y) as? Double) ?? 0.3
        )

        panel = FloatingPanel(size: Self.panelSize, allowsKey: false)
        // Уровнем выше чата: орб стоит у поля ввода и не должен уходить под его тень.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        // Кнопка не уезжает в Mission Control вместе с окнами.
        panel.collectionBehavior.insert(.stationary)
        panel.acceptsMouseMovedEvents = true
        // Пока курсор не над шаром, прозрачная панель пропускает клики насквозь.
        panel.ignoresMouseEvents = true

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
        watchPointer()
        scheduleRetract()
    }

    /// Центр орба на экране.
    var orbCenter: NSPoint {
        NSPoint(x: panel.frame.midX, y: panel.frame.midY)
    }

    /// Отводит прицепленный орб от края и возвращает рамку, где он встанет.
    /// Свободный орб никуда не едет.
    @discardableResult
    func detach() -> NSRect {
        guard state.dock != nil, !state.isDetached else { return panel.frame }
        cancelRetract()
        state.isRetracted = false
        state.isDetached = true
        let target = frame(on: currentScreen)
        layout(animated: true, duration: 0.16)
        return target
    }

    /// Возвращает отошедший орб к краю.
    func reattach() {
        guard state.isDetached else { return }
        state.isDetached = false
        layout(animated: true)
        scheduleRetract()
    }

    // MARK: - Уход за край

    /// Прицепленный орб без дела через несколько секунд уходит за край, как у Eney.
    private func scheduleRetract() {
        retractTask?.cancel()
        guard state.isAttached, !state.isRetracted else { return }
        retractTask = Task { [weak self] in
            try? await Task.sleep(for: Self.retractDelay)
            guard !Task.isCancelled, let self, self.state.isAttached, !self.chatLayout.isOpen,
                  self.pressLocation == nil, !self.isOverOrb(NSEvent.mouseLocation) else { return }
            self.state.isRetracted = true
        }
    }

    private func cancelRetract() {
        retractTask?.cancel()
        retractTask = nil
    }

    // MARK: - Мышь

    /// Панель квадратная и заметно больше шара, а орб теперь может стоять посреди
    /// экрана и рядом с полем ввода. Чтобы прозрачные углы не отнимали клики у чужих
    /// окон и у кнопки отправки, панель ловит мышь, только когда курсор над шаром.
    private func watchPointer() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        let update: () -> Void = { [weak self] in
            self?.updateMousePassThrough(at: NSEvent.mouseLocation)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in
            MainActor.assumeIsolated { update() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { update() }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func updateMousePassThrough(at location: NSPoint) {
        // Во время нажатия панель едет под курсором и должна получать события до конца.
        guard pressLocation == nil else { return }
        let over = isOverOrb(location)
        if panel.ignoresMouseEvents == over {
            panel.ignoresMouseEvents = !over
        }
        // Курсор подошёл — орб выходит из-за края; ушёл — через паузу прячется снова.
        if over {
            cancelRetract()
            if state.isRetracted { state.isRetracted = false }
        } else if state.isAttached, !state.isRetracted, retractTask == nil {
            scheduleRetract()
        }
    }

    private func isOverOrb(_ location: NSPoint) -> Bool {
        let center = orbCenter
        let scale = chatLayout.isOpen ? Self.openScale : 1
        let radius = Self.orbDiameter / 2 * scale + 8
        if hypot(location.x - center.x, location.y - center.y) <= radius {
            return true
        }
        // За горб у края тоже можно взяться. Спрятанный орб выходит, стоит курсору
        // дойти до горбика у кромки.
        guard state.isAttached, let dock = state.dock, abs(location.y - center.y) <= 40 else { return false }
        return dock == .right ? location.x >= center.x - 4 : location.x <= center.x + 4
    }

    fileprivate func mouseDown(at location: NSPoint) {
        pressLocation = location
        cancelRetract()
        state.isRetracted = false
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
        }

        var origin = NSPoint(
            x: location.x - grabOffset.width,
            y: location.y - grabOffset.height
        )
        // Выше середины экрана орб не поднимается: он живёт в нижней половине.
        let visible = screen(containing: location).visibleFrame
        let half = Self.panelSize.height / 2
        origin.y = min(max(origin.y + half, visible.minY + Self.bottomLimit), visible.midY) - half
        panel.setFrameOrigin(origin)
        onMove?()
    }

    fileprivate func mouseUp(at location: NSPoint) {
        defer {
            pressLocation = nil
            state.isPressed = false
            state.isDragging = false
            updateMousePassThrough(at: location)
        }

        guard state.isDragging else {
            onClick?()
            return
        }

        let screen = screen(containing: location)
        let full = screen.frame
        let visible = screen.visibleFrame
        let center = orbCenter

        if center.x >= full.maxX - Self.dockZone {
            state.dock = .right
        } else if center.x <= full.minX + Self.dockZone {
            state.dock = .left
        } else {
            state.dock = nil
            position.x = (center.x - visible.minX) / max(visible.width, 1)
        }
        // При открытом чате прицепленный орб остаётся в стороне от края до закрытия.
        state.isDetached = state.dock != nil && chatLayout.isOpen
        position.y = (center.y - visible.minY) / max(visible.height, 1)

        save()
        layout(animated: true, on: screen)
        scheduleRetract()
    }

    fileprivate func menu() -> NSMenu? {
        makeMenu?()
    }

    // MARK: - Геометрия

    private var currentScreen: NSScreen {
        screen(containing: orbCenter)
    }

    private func screen(containing point: NSPoint) -> NSScreen {
        NSScreen.screens.first { $0.frame.contains(point) } ?? panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func layout(
        animated: Bool,
        on screen: NSScreen? = nil,
        duration: TimeInterval = 0.3,
        completion: (@MainActor () -> Void)? = nil
    ) {
        let target = frame(on: screen ?? currentScreen)
        guard animated else {
            panel.setFrame(target, display: true)
            onMove?()
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.onMove?()
                completion?()
            }
        }
    }

    private func frame(on screen: NSScreen) -> NSRect {
        let full = screen.frame
        let visible = screen.visibleFrame

        let y = min(
            max(visible.minY + position.y * visible.height, visible.minY + Self.bottomLimit),
            visible.midY
        )

        // Прицепленный орб считается от настоящей кромки экрана: он держится именно
        // за неё, а не за границу видимой области.
        let x: CGFloat
        switch (state.dock, state.isDetached) {
        case (.right, false): x = full.maxX - Self.attachedInset
        case (.right, true): x = full.maxX - Self.detachedInset
        case (.left, false): x = full.minX + Self.attachedInset
        case (.left, true): x = full.minX + Self.detachedInset
        case (nil, _):
            x = min(
                max(visible.minX + position.x * visible.width, visible.minX + Self.freeInset),
                visible.maxX - Self.freeInset
            )
        }

        let size = Self.panelSize
        return NSRect(x: x - size.width / 2, y: y - size.height / 2, width: size.width, height: size.height)
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(state.dock?.rawValue ?? "none", forKey: DefaultsKey.dock)
        defaults.set(Double(position.x), forKey: DefaultsKey.x)
        defaults.set(Double(position.y), forKey: DefaultsKey.y)
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
