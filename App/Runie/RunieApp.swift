import SwiftUI

@main
struct RunieApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Окон у Runie нет: кнопка и чат — плавающие панели, ими управляет делегат.
        // Пустая сцена настроек нужна только потому, что App обязан объявить сцену.
        Settings {
            EmptyView()
        }
    }
}
