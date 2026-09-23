import AppKit
import Observation
import RunieKit
import SwiftUI

/// Состояние раскладки чата, общее для контроллера и SwiftUI.
@MainActor
@Observable
final class ChatLayout {
    /// С какой стороны от блоков стоит орб: к нему блоки и прижимаются.
    var orbSide: HorizontalEdge = .trailing
    /// Сигнал «поставь фокус в поле ввода». Панель переиспользуется, поэтому
    /// `onAppear` срабатывает один раз, а показывать её можно сколько угодно.
    private(set) var focusGeneration = 0
    /// Черновик сообщения. Живёт здесь, а не во вьюхе: отправляет его орб,
    /// а орб — это другое окно.
    var draft = ""
    /// Отправлять ли агенту, в каком приложении сейчас человек.
    var includesContext = true
    /// Чат открыт. Орб по этому решает, что делать с кликом.
    var isOpen = false
    /// Меняется при каждом открытии — чтобы поле заново «вытекло» из орба.
    private(set) var openGeneration = 0

    /// Картинки и файлы к ещё не отправленному сообщению.
    var attachments: [Attachment] = []

    /// Есть что отправить: текст или вложения.
    var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    func requestFocus() {
        focusGeneration += 1
    }

    func markOpened() {
        isOpen = true
        openGeneration += 1
    }
}

/// Чат без подложки: отдельные стеклянные блоки у орба.
///
/// Окно прозрачное и заметно больше видимых блоков — в нём хватает места для
/// развёрнутой переписки и теней. Поле ввода стоит вровень с орбом и заканчивается
/// в шаге от сжавшегося ядра: клик по ядру закрывает чат.
@MainActor
final class ChatPanelController {

    /// Наибольший размер окна. Высота подстраивается под место над орбом.
    /// Ширина — ради поля ввода: в 380 точек ему доставалось едва на «Спросите Руни…».
    static let size = NSSize(width: 480 + shadowMargin * 2, height: 640)
    /// Прозрачное поле вокруг блоков. Тень блока выходит далеко за его край,
    /// и если поля не хватает, край окна обрезает её прямой линией.
    static let shadowMargin: CGFloat = 40
    /// Меньше этого окно не сжимается: иначе ответу негде поместиться.
    private static let minimumHeight: CGFloat = 320
    /// Высота ряда подсказок под полем ввода.
    static let chipsHeight: CGFloat = 36
    /// Высота поля ввода. Чуть больше орба (48), чтобы шар лежал в поле с зазором.
    static let inputHeight: CGFloat = 56
    /// От центра орба до ближнего конца поля ввода: сжавшееся ядро и зазор.
    static let orbGap: CGFloat = EdgeButtonController.orbDiameter * EdgeButtonController.openScale / 2 + 10
    static let blockSpacing: CGFloat = 10
    static var bottomInset: CGFloat { shadowMargin }
    private static let screenInset: CGFloat = 8

    /// Расстояние от низа окна до середины поля ввода — по нему окно
    /// выравнивается относительно орба.
    private static var inputCenterFromBottom: CGFloat {
        bottomInset + chipsHeight + blockSpacing + inputHeight / 2
    }

    let panel: FloatingPanel
    let layout = ChatLayout()
    private let session: ChatSession
    private let tracker: FrontmostAppTracker
    private let setup: SetupModel

    /// Меняется при каждом показе и скрытии. Анимация скрытия убирает панель, только
    /// если за время анимации её не открыли снова.
    private var visibilityGeneration = 0
    private var pasteMonitor: Any?
    private var settingsMonitor: Any?

    /// ⌘, в чате — открыть настройки Runie.
    var onOpenSettings: (() -> Void)?
    private var isHiding = false

    /// Кнопка масштабирования: открыть разговор в окне Runie.
    var onOpenWindow: (() -> Void)?

    /// Чат начал закрываться — откуда бы ни пришла команда: орб, Esc, крестик.
    var onHide: (() -> Void)?

    init(
        session: ChatSession,
        tracker: FrontmostAppTracker,
        settings: AppSettings,
        setup: SetupModel,
        suggestions: SuggestionsModel,
        briefing: MorningBriefing
    ) {
        self.session = session
        self.tracker = tracker
        self.setup = setup
        panel = FloatingPanel(size: Self.size, allowsKey: true)

        let layout = self.layout
        let hosting = NSHostingView(rootView: ChatView(
            session: session,
            settings: settings,
            setup: setup,
            layout: layout,
            tracker: tracker,
            suggestions: suggestions,
            briefing: briefing,
            onSend: { [weak self] text in self?.send(text) },
            onClose: { [weak self] in self?.hide() },
            onOpenWindow: { [weak self] in self?.onOpenWindow?() },
            onPickFiles: { [weak self] in self?.pickFiles() },
            onCapture: { [weak self] in self?.captureScreenshot() },
            onPaste: { [weak self] in self?.pasteClipboard() },
            onRetry: { [weak self] in self?.retry() },
            onRefocus: { [weak self] in
                guard let self, self.isVisible else { return }
                self.panel.makeKey()
                self.layout.requestFocus()
            }
        ))
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.onCancel = { [weak self] in self?.cancel() }
        // ⌘, — как в любом приложении Mac: настройки. Чат-панель не главное окно,
        // и меню приложения её не видит, поэтому сочетание ловится здесь.
        let panel = self.panel
        settingsMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Сравниваем и символ, и физическую клавишу (код 43 — «,» на английской
            // раскладке): на русской та же клавиша даёт «б», и по символу ⌘, не ловится.
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.keyCode == 43 || event.charactersIgnoringModifiers == ","
            else { return event }
            let windowNumber = event.windowNumber
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard windowNumber == panel.windowNumber, let open = self?.onOpenSettings else { return false }
                open()
                return true
            }
            return handled ? nil : event
        }
        pasteMonitor = AttachmentStore.installPasteHandler(for: { [weak self] in self?.panel }) { [weak self] files in
            guard let self else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { self.layout.attachments += files }
        }
        // Орб решает по движению курсора, пропускать ли клики сквозь себя; над чатом
        // эти события приходят только в окно чата.
        panel.acceptsMouseMovedEvents = true
    }

    /// Видим и не уезжает прямо сейчас.
    var isVisible: Bool { panel.isVisible && !isHiding }

    /// Отправляет сообщение с контекстом приложения, если он включён. Черновик не
    /// трогает: подсказки уходят мимо него.
    func send(_ text: String) {
        guard !session.isBusy, setup.isReady else { return }
        let context = layout.includesContext ? tracker.current?.context : nil
        session.send(text, context: context, attachments: layout.attachments)
        layout.attachments = []
    }

    /// Отправляет последнее сообщение ещё раз.
    func retry() {
        guard !session.isBusy, setup.isReady else { return }
        session.retry(context: layout.includesContext ? tracker.current?.context : nil)
    }

    /// Снимок области: чат прячется, чтобы не попасть в кадр и не мешать выделению,
    /// и возвращается со снимком во вложениях.
    func captureScreenshot() {
        panel.orderOut(nil)
        Task { @MainActor in
            // Список со скрепки успевает уехать и не попадает в кадр.
            try? await Task.sleep(for: .milliseconds(200))
            let shot = await AttachmentStore.captureArea()
            if layout.isOpen {
                panel.orderFrontRegardless()
                panel.makeKey()
                layout.requestFocus()
            }
            if let shot {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { layout.attachments.append(shot) }
            }
        }
    }

    /// Буфер обмена: файлы и картинка — во вложения, текст — в поле ввода.
    func pasteClipboard() {
        let (files, text) = AttachmentStore.readClipboard()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { layout.attachments += files }
        if let text {
            layout.draft += (layout.draft.isEmpty ? "" : " ") + text
        }
        panel.makeKey()
        layout.requestFocus()
    }

    func pickFiles() {
        let files = AttachmentStore.pickFiles()
        panel.makeKeyAndOrderFront(nil)
        layout.requestFocus()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { layout.attachments += files }
    }

    func toggle(anchor: NSRect) {
        isVisible ? hide() : show(anchor: anchor)
    }

    func show(anchor: NSRect) {
        visibilityGeneration += 1
        let target = frame(anchor: anchor)

        if isHiding {
            // Передумали закрывать: возвращаем прозрачность, панель ещё на экране.
            isHiding = false
            layout.isOpen = true
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
        layout.markOpened()
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
        layout.isOpen = false
        GlassDropdown.shared.close()
        onHide?()

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

    /// Esc закрывает чат.
    private func cancel() {
        hide()
    }

    /// Блоки открываются в сторону центра экрана от орба, поле ввода вровень с ним
    /// и заканчивается в шаге от ядра.
    private func frame(anchor: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let size = Self.size
        let orbOnRight = anchor.midX > screen.frame.midX
        layout.orbSide = orbOnRight ? .trailing : .leading

        // Ближний конец поля — в шаге от ядра. Считаем от центра орба, а не от
        // прозрачных полей обоих окон.
        var x = orbOnRight
            ? anchor.midX - Self.orbGap + Self.shadowMargin - size.width
            : anchor.midX + Self.orbGap - Self.shadowMargin
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
