import AppKit

/// Безрамочная панель поверх всех окон, которая не активирует приложение.
///
/// Runie живёт поверх чужих приложений: клик по кнопке у края не должен уводить
/// фокус из того, где человек работал. Чат при этом обязан принимать ввод с
/// клавиатуры, поэтому возможность стать key-окном включается отдельно.
final class FloatingPanel: NSPanel {

    private let allowsKey: Bool

    /// Esc внутри панели.
    var onCancel: (() -> Void)?

    init(size: NSSize, allowsKey: Bool) {
        self.allowsKey = allowsKey
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        // На всех рабочих столах и поверх полноэкранных приложений, без участия
        // в переключении окон.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    /// AppKit по умолчанию вталкивает окно обратно в экран, если оно залезает под
    /// строку меню или за край. У Runie за край намеренно заходят прозрачные поля
    /// под тень и свечение, а видимое положение считают контроллеры. Без этой
    /// поправки окно чата съезжало вниз, и поле ввода уходило ниже орба.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Пункт меню с замыканием вместо пары target-action.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
    }

    required init(coder: NSCoder) {
        fatalError("не используется")
    }

    @objc private func run() {
        handler()
    }
}
