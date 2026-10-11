import Observation
import ServiceManagement

/// «Открывать при входе в систему» — через `SMAppService`, как пункт «Объекты
/// входа» в Системных настройках. Состояние спрашиваем у системы, а не храним:
/// человек может выключить Runie и там.
@MainActor
@Observable
final class LaunchAtLogin {

    static let shared = LaunchAtLogin()

    private(set) var isEnabled = false
    /// Включили, но macOS ждёт подтверждения в Системных настройках.
    private(set) var needsApproval = false
    private(set) var failure: String?

    private init() {
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func set(_ enabled: Bool) {
        failure = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            failure = error.localizedDescription
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
