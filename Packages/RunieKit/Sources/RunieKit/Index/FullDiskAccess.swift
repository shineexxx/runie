import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Полный доступ к диску: есть он или нет и как его дать.
///
/// macOS не сообщает об этом напрямую — узнать можно только попыткой. Пробуем
/// прочитать файл, который без этого разрешения не читается никогда: саму базу
/// разрешений. Запрет возвращается ошибкой, окон система не показывает.
///
/// Разрешение вступает в силу после перезапуска приложения — macOS решает это
/// один раз, при запуске.
public enum FullDiskAccess {

    /// Файлы-пробники. Первый есть у всех; второй на случай, если Apple уберёт первый.
    private static var probes: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appending(path: "Library/Application Support/com.apple.TCC/TCC.db"),
            home.appending(path: "Library/Safari/CloudTabs.db")
        ]
    }

    /// Выдан ли полный доступ к диску.
    public static var isGranted: Bool {
        for probe in probes where FileManager.default.fileExists(atPath: probe.path) {
            // Читаем один байт: содержимое не нужно, нужен сам факт доступа.
            guard let handle = try? FileHandle(forReadingFrom: probe) else { return false }
            defer { try? handle.close() }
            return (try? handle.read(upToCount: 1)) != nil
        }
        // Пробников нет — судить не по чему; считаем, что доступа нет.
        return false
    }

    /// Открывает «Конфиденциальность и безопасность» → «Полный доступ к диску».
    public static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }

    /// Перезапускает Runie: без этого новое разрешение не подхватится.
    public static func restartApp() {
        #if canImport(AppKit)
        let bundle = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
        #endif
    }
}
