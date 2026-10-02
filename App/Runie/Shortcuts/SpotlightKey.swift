import AppKit
import os

/// Клавиша Spotlight (лупа на F4) открывает Руни вместо Spotlight.
///
/// Системной настройки для этого нет: клавишу поиска macOS отдаёт Spotlight сам.
/// Поэтому Руни ставит перехватчик нажатий раньше системы, «съедает» эту клавишу
/// и открывает чат. Для перехватчика нужен Универсальный доступ. Выключили
/// настройку или забрали доступ — клавиша снова открывает Spotlight.
///
/// На встроенной клавиатуре MacBook клавиша поиска приходит как отдельный код
/// 177. Остальные клавиатуры могут присылать её иначе — поэтому коды служебных
/// клавиш (не букв: они в журнал не попадают) пишутся в системный журнал.
@MainActor
final class SpotlightKey {

    static let shared = SpotlightKey()

    nonisolated static let enabledKey = "shortcuts.spotlightKey"
    /// Код клавиши поиска на клавиатурах Mac с Apple Silicon.
    nonisolated static let searchKeyCode: Int64 = 177

    var onPress: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// Включает или выключает перехват по настройке.
    func apply() {
        stop()
        guard isEnabled, AXIsProcessTrusted() else { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, _ in SpotlightKey.handle(type: type, event: event) },
            userInfo: nil
        ) else { return }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    nonisolated private static let log = Logger(subsystem: "app.runie.Runie", category: "spotlight-key")

    /// Вызывается системой на каждое нажатие, поэтому коротко: свои клавиши
    /// съедаем, остальные пропускаем как есть.
    nonisolated private static func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Система отключает перехватчик, если он задумался, — включаем обратно.
            DispatchQueue.main.async { MainActor.assumeIsolated { SpotlightKey.shared.reenable() } }
            return Unmanaged.passUnretained(event)
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        // Служебные клавиши (поиск, диктовка, «Не беспокоить») — коды выше 160.
        // Буквы и цифры сюда не попадают, текст человека в журнал не пишется.
        if code >= 160, type == .keyDown {
            log.info("special key \(code, privacy: .public)")
        }
        guard code == searchKeyCode else { return Unmanaged.passUnretained(event) }
        if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            DispatchQueue.main.async { MainActor.assumeIsolated { SpotlightKey.shared.onPress?() } }
        }
        // И нажатие, и отпускание — себе: Spotlight их не увидит.
        return nil
    }
}
