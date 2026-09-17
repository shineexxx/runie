import Foundation
import Observation
import RunieKit

/// Быстрые команды из настроек — для раздела «Мои команды» и подсказок по «/».
@MainActor
@Observable
final class QuickCommandsModel {

    static let shared = QuickCommandsModel()

    private(set) var commands: [QuickCommand] = []

    private init() {
        reload()
    }

    func reload() {
        commands = RunieExtensions.plugin.commands()
    }

    /// Сохраняет и сообщает Руни: команда заработает со следующего сообщения.
    func save(_ command: QuickCommand, replacing previous: String?) throws {
        try RunieExtensions.plugin.saveCommand(command, replacing: previous)
        reload()
        RunieExtensions.onChange?()
    }

    func remove(_ command: QuickCommand) {
        try? RunieExtensions.plugin.removeCommand(named: command.name)
        reload()
        RunieExtensions.onChange?()
    }
}
