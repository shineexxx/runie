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

    /// Прокрутка, которую никто внутри не подхватил, заканчивается здесь.
    ///
    /// До окна событие доходит последним — после всех видов. Если чат уже
    /// прокрутился, сюда не попадёт ничего; а вот прокрутка над ответом, который
    /// прокручивать нечего, раньше уходила окну позади, и человек крутил чужое
    /// приложение, ведя мышью по словам Руни.
    override func scrollWheel(with event: NSEvent) {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "RunieTraceScroll") {
            RunieTrace.note("панель съела прокрутку")
        }
        #endif
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

extension NSWindow {
    /// Показывает окно поверх чужих приложений.
    ///
    /// Runie живёт без иконки в Dock, а его окна открываются из панели, которая
    /// нарочно не активирует приложение. Без прямой просьбы система оставляет
    /// окно позади того, где человек работал, и он его просто не находит.
    func showInFront() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
        // Политика Dock меняется не мгновенно: пока она доедет, система успевает
        // оставить окно позади. Повторяем на следующем обороте цикла — иначе
        // человек нажимает ⌘, и не находит настроек.
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.makeKeyAndOrderFront(nil)
            self?.orderFrontRegardless()
        }
    }
}

extension NSApplication {
    /// Убирает Runie из Dock, когда обычных окон больше не осталось.
    ///
    /// Переключать политику на `.accessory` сразу при закрытии окна нельзя: она
    /// прячет все обычные окна приложения разом. Закрыв одно окно, человек
    /// терял и остальные — например, главное окно вместе с рассказом об указателе.
    func hideFromDockIfNoOrdinaryWindowsLeft(besides closing: NSWindow?) {
        let stillOpen = windows.contains { window in
            window !== closing && window.isVisible && !(window is NSPanel)
        }
        guard !stillOpen else { return }
        setActivationPolicy(.accessory)
    }
}

#if DEBUG
/// Запись отладочных заметок в файл из `-RunieTrace`.
enum RunieTrace {
    private static let lock = NSLock()

    static func note(_ text: String) {
        guard let path = UserDefaults.standard.string(forKey: "RunieTrace") else { return }
        lock.lock()
        defer { lock.unlock() }
        let line = text + "\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
#endif
