import AppKit
import Carbon.HIToolbox
import Observation

/// Сочетание клавиш: код клавиши, модификаторы и как его показать человеку.
struct KeyCombo: Codable, Equatable, Sendable {
    let keyCode: UInt32
    /// Модификаторы в виде Carbon (`cmdKey`, `optionKey`…): так их ждёт система.
    let modifiers: UInt32
    /// Сама клавиша так, как её напечатала раскладка при записи: «S», «Space».
    let key: String

    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + key
    }

    /// Из нажатия в окне записи. Без модификатора сочетание не годится: оно
    /// перехватило бы обычную букву во всех приложениях.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        guard carbon != 0, carbon != UInt32(shiftKey) else { return nil }
        keyCode = UInt32(event.keyCode)
        modifiers = carbon
        key = Self.name(for: event)
    }

    init(keyCode: Int, modifiers: Int, key: String) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = UInt32(modifiers)
        self.key = key
    }

    private static func name(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default:
            // Латинская буква по коду клавиши, а не по раскладке: на русской
            // та же клавиша дала бы «Ы», а сочетание всё равно одно.
            if let latin = latinKeys[Int(event.keyCode)] { return latin }
            return (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }

    private static let latinKeys: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8",
        kVK_ANSI_9: "9"
    ]
}

/// Сочетания клавиш Руни, работающие из любого приложения.
///
/// Чат вызывается двойным нажатием ⌥ — руки не уходят с клавиатуры, и оно не
/// спорит ни с Raycast (⌥Space), ни со Spotlight, ни с Siri (двойной ⌘). Вместо
/// него можно записать своё сочетание. «Спросить про экран» и «Новый разговор» —
/// обычные сочетания, их тоже можно переписать или убрать.
///
/// Обычные сочетания регистрируются системой и разрешений не требуют. Двойной ⌥
/// Руни ловит сам, слушая модификаторы, — для этого нужен Универсальный доступ.
@MainActor
@Observable
final class GlobalShortcuts {

    static let shared = GlobalShortcuts()

    enum Action: String, CaseIterable, Sendable {
        case toggleChat
        case askAboutScreen
        case newConversation
    }

    /// Как вызывать чат.
    enum ChatTrigger: String, CaseIterable, Sendable {
        case doubleOption
        case combo
        case off
    }

    var chatTrigger: ChatTrigger {
        didSet { save(); apply() }
    }

    /// Сочетания по действиям. `nil` — у действия сочетания нет.
    private(set) var combos: [Action: KeyCombo]

    /// Что делать по нажатию — назначает `AppDelegate`.
    @ObservationIgnored var handler: ((Action) -> Void)?

    static let defaults: [Action: KeyCombo] = [
        .toggleChat: KeyCombo(keyCode: kVK_Space, modifiers: optionKey | cmdKey, key: "Space"),
        .askAboutScreen: KeyCombo(keyCode: kVK_ANSI_S, modifiers: controlKey | optionKey, key: "S"),
        .newConversation: KeyCombo(keyCode: kVK_ANSI_N, modifiers: controlKey | optionKey, key: "N")
    ]

    private enum Key {
        static let trigger = "shortcuts.chatTrigger"
        static let combos = "shortcuts.combos"
    }

    @ObservationIgnored private var registered: [EventHotKeyRef] = []
    @ObservationIgnored private var handlerRef: EventHandlerRef?
    @ObservationIgnored private var modifierMonitors: [Any] = []
    /// Пока идёт запись сочетания, свои же сочетания молчат.
    @ObservationIgnored var isRecording = false {
        didSet { apply() }
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: Key.trigger).flatMap(ChatTrigger.init(rawValue:))
        chatTrigger = stored ?? .doubleOption
        if let data = UserDefaults.standard.data(forKey: Key.combos),
           let saved = try? JSONDecoder().decode([String: KeyCombo?].self, from: data) {
            var combos = Self.defaults
            for (name, combo) in saved {
                guard let action = Action(rawValue: name) else { continue }
                combos[action] = combo
            }
            self.combos = combos
        } else {
            combos = Self.defaults
        }
    }

    func start() {
        installHandler()
        apply()
    }

    func combo(for action: Action) -> KeyCombo? { combos[action] ?? nil }

    func setCombo(_ combo: KeyCombo?, for action: Action) {
        combos[action] = combo
        save()
        apply()
    }

    func resetToDefaults() {
        combos = Self.defaults
        chatTrigger = .doubleOption
    }

    /// Двойной ⌥ слышен только с Универсальным доступом.
    var needsAccessibility: Bool {
        chatTrigger == .doubleOption && !AXIsProcessTrusted()
    }

    func openAccessibilitySettings() {
        // Строка ключа вместо `kAXTrustedCheckOptionPrompt`: та — изменяемая глобальная
        // переменная, и Swift 6 её не пускает.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private func save() {
        UserDefaults.standard.set(chatTrigger.rawValue, forKey: Key.trigger)
        var stored: [String: KeyCombo?] = [:]
        // updateValue, а не подстановка: `= nil` удалило бы ключ, и снятое
        // сочетание после перезапуска вернулось бы к стандартному.
        for action in Action.allCases { stored.updateValue(combos[action], forKey: action.rawValue) }
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Key.combos)
        }
    }

    // MARK: Системные сочетания

    private func installHandler() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let index = Int(id.id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let actions = Action.allCases
                    guard actions.indices.contains(index) else { return }
                    GlobalShortcuts.shared.handler?(actions[index])
                }
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    private func apply() {
        registered.forEach { UnregisterEventHotKey($0) }
        registered.removeAll()
        modifierMonitors.forEach { NSEvent.removeMonitor($0) }
        modifierMonitors.removeAll()
        guard !isRecording else { return }

        for (index, action) in Action.allCases.enumerated() {
            if action == .toggleChat, chatTrigger != .combo { continue }
            guard let combo = combo(for: action) else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x524E_4945), id: UInt32(index)) // 'RNIE'
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { registered.append(ref) }
        }
        if chatTrigger == .doubleOption { watchDoubleOption() }
    }

    // MARK: Двойной ⌥

    /// Когда отпустили ⌥ в последний раз — если отпустят снова быстро, это двойное нажатие.
    @ObservationIgnored private var lastTap: Date?
    /// Когда нажали ⌥ сейчас. Долгое удержание — не нажатие.
    @ObservationIgnored private var pressedAt: Date?
    /// Пока ⌥ зажат, нажали другую клавишу: это сочетание или спецсимвол, не нажатие.
    @ObservationIgnored private var interrupted = false

    private static let tapLength: TimeInterval = 0.3
    private static let doubleTapGap: TimeInterval = 0.4

    private func watchDoubleOption() {
        let flags: (NSEvent) -> Void = { event in
            MainActor.assumeIsolated { GlobalShortcuts.shared.modifiersChanged(event) }
        }
        let keys: (NSEvent) -> Void = { _ in
            MainActor.assumeIsolated { GlobalShortcuts.shared.keyPressed() }
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) {
            modifierMonitors.append(monitor)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys) {
            modifierMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            flags(event)
            return event
        }) {
            modifierMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            keys(event)
            return event
        }) {
            modifierMonitors.append(monitor)
        }
    }

    private func keyPressed() {
        interrupted = true
        lastTap = nil
    }

    private func modifiersChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
        let now = Date()
        if flags == .option {
            // Нажали один ⌥ — без других модификаторов.
            pressedAt = now
            interrupted = false
            return
        }
        guard flags.isEmpty, let pressed = pressedAt else {
            // Добавили ещё модификатор — это уже сочетание.
            pressedAt = nil
            lastTap = nil
            return
        }
        pressedAt = nil
        guard !interrupted, now.timeIntervalSince(pressed) < Self.tapLength else {
            lastTap = nil
            return
        }
        if let last = lastTap, now.timeIntervalSince(last) < Self.doubleTapGap {
            lastTap = nil
            handler?(.toggleChat)
        } else {
            lastTap = now
        }
    }
}
