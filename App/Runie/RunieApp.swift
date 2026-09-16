import SwiftUI

@main
struct RunieApp: App {
    var body: some Scene {
        WindowGroup("Runie") {
            ContentView()
                .frame(minWidth: 420, minHeight: 320)
        }
        .windowResizability(.contentMinSize)
    }
}
