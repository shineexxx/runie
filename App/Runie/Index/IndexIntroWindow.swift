import AppKit
import Observation
import RunieKit
import SwiftUI

/// Состояние приглашения: чего не хватает и что показывать человеку.
@MainActor
@Observable
final class IndexIntroModel {

    enum State: Equatable {
        /// Разрешения нет — объясняем и зовём в настройки.
        case needsAccess
        /// Разрешение появилось, но применится после перезапуска.
        case needsRestart
        case ready
    }

    private(set) var state: State = .needsAccess
    /// Ждём, пока человек щёлкнет переключатель в настройках.
    private(set) var isWatching = false

    var onClose: (() -> Void)?

    /// Доступ был при запуске приложения: только такой уже работает.
    private let grantedAtLaunch = FullDiskAccess.isGranted

    func refresh() {
        state = grantedAtLaunch ? .ready : (FullDiskAccess.isGranted ? .needsRestart : .needsAccess)
        // Доступ выдан, а человек ещё ничего не выбирал — включаем всё сразу:
        // он дал доступ именно для этого, а пустые переключатели выглядели бы
        // так, будто ничего не произошло.
        if state == .ready, !IndexModel.shared.didChoose {
            IndexModel.shared.enableEverything()
        }
    }

    func openSettings() {
        FullDiskAccess.openSettings()
        watch()
    }

    func restart() { FullDiskAccess.restartApp() }

    func dismiss() {
        stopWatching()
        onClose?()
    }

    /// Пока окно настроек открыто, проверяем разрешение: человеку не нужно
    /// возвращаться и нажимать «Проверить».
    private func watch() {
        guard !isWatching else { return }
        isWatching = true
        watcher = Task { [weak self] in
            for _ in 0..<600 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if FullDiskAccess.isGranted {
                    state = grantedAtLaunch ? .ready : .needsRestart
                    stopWatching()
                    NSApp.activate()
                    return
                }
            }
            self?.stopWatching()
        }
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
        isWatching = false
    }

    @ObservationIgnored private var watcher: Task<Void, Never>?
}

/// Окно приглашения. Отдельное от главного: это разговор про одно решение,
/// а не ещё одна вкладка настроек.
@MainActor
final class IndexIntroWindowController: NSObject, NSWindowDelegate {

    static let shared = IndexIntroWindowController()

    private var window: NSWindow?

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        window.showInFront()
    }

    private func makeWindow() -> NSWindow {
        let model = IndexIntroModel()
        model.onClose = { [weak self] in self?.window?.performClose(nil) }
        // Высота — по экрану: на ноутбуке окно в 900 точек просто не помещается,
        // а содержимое всё равно прокручивается.
        let available = NSScreen.main?.visibleFrame.height ?? 900
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: min(900, available - 60)),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Индекс Руни")
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        window.contentView = NSHostingView(rootView: IndexIntroView(model: model))
        return window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        NSApp.hideFromDockIfNoOrdinaryWindowsLeft(besides: notification.object as? NSWindow)
    }
}
