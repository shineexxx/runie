import Foundation

/// Пространство имён для сведений о самом приложении.
public enum Runie {
    /// Версия из Info.plist приложения — её ставит скрипт выпуска. Зашитая здесь
    /// строка отставала: в настройках всегда было «0.0.1».
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
    public static let bundleIdentifier = "app.runie.Runie"
}
