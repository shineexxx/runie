import AppKit
import SwiftUI

/// Раздел «Сочетания клавиш» в настройках.
struct ShortcutRows: View {
    private let shortcuts = GlobalShortcuts.shared

    var body: some View {
        Picker(selection: Binding(get: { shortcuts.chatTrigger }, set: { shortcuts.chatTrigger = $0 })) {
            Text("Двойной ⌥").tag(GlobalShortcuts.ChatTrigger.doubleOption)
            Text("Своё сочетание").tag(GlobalShortcuts.ChatTrigger.combo)
            Text("Выключено").tag(GlobalShortcuts.ChatTrigger.off)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("Открыть чат")
                Text("Из любого приложения, без похода к краю экрана. Повторное нажатие закрывает чат.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .pickerStyle(.menu)

        if shortcuts.chatTrigger == .combo {
            ShortcutRow(title: String(localized: "Сочетание для чата"), action: .toggleChat)
        }
        if shortcuts.needsAccessibility {
            HStack {
                Text("Чтобы Руни слышал двойной ⌥ в других приложениях, нужен Универсальный доступ.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Открыть настройки") { shortcuts.openAccessibilitySettings() }
            }
        }

        ShortcutRow(
            title: String(localized: "Спросить про экран"),
            detail: String(localized: "Открывает чат со снимком экрана во вложении"),
            action: .askAboutScreen
        )
        ShortcutRow(title: String(localized: "Новый разговор"), action: .newConversation)
    }
}

/// Строка с сочетанием: показать, записать новое, убрать.
private struct ShortcutRow: View {
    let title: String
    var detail: String?
    let action: GlobalShortcuts.Action

    private let shortcuts = GlobalShortcuts.shared
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: toggleRecording) {
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .frame(minWidth: 90)
            }
            .help(recording ? "Нажмите сочетание, Esc — отмена" : "Нажмите, чтобы записать новое сочетание")
            if shortcuts.combo(for: action) != nil, !recording {
                Button {
                    shortcuts.setCombo(nil, for: action)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Убрать сочетание")
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private var label: String {
        if recording { return String(localized: "Нажмите…") }
        return shortcuts.combo(for: action)?.display ?? String(localized: "Не задано")
    }

    private func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        recording = true
        shortcuts.isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                stopRecording()
                return nil
            }
            guard let combo = KeyCombo(event: event) else { return nil }
            shortcuts.setCombo(combo, for: action)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        shortcuts.isRecording = false
    }
}
