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
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let model = IndexIntroModel()
        model.onClose = { [weak self] in self?.window?.performClose(nil) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 900),
            styleMask: [.titled, .closable, .fullSizeContentView],
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
        NSApp.setActivationPolicy(.accessory)
    }
}
