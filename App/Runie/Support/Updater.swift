import AppKit
import Observation
import Sparkle
import SwiftUI

/// Самообновление через Sparkle: Runie смотрит appcast на GitHub, проверяет подпись
/// выпуска и ставит новую версию сам. Файл подписан ключом, который лежит только у
/// автора, — подменить обновление по дороге нельзя.
@MainActor
@Observable
final class UpdaterModel {

    static let shared = UpdaterModel()

    private(set) var canCheck = true
    /// Что показать в настройках после проверки.
    private(set) var status: String?

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private let driverDelegate = DriverDelegate()
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: driverDelegate
        )
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor in self?.canCheck = updater.canCheckForUpdates }
        }
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? { controller.updater.lastUpdateCheckDate }

    /// Проверить сейчас — по кнопке в настройках.
    func check() {
        // Приложение живёт без иконки в Dock: окно Sparkle должно выйти вперёд.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

/// Окно обновления у приложения без иконки в Dock само вперёд не выходит.
private final class DriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        NSApp.activate(ignoringOtherApps: true)
    }
}
