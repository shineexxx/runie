import RunieKit
import SwiftUI

struct MainWindowView: View {
    @Bindable var navigation: MainNavigation
    let session: ChatSession
    let settings: AppSettings
    let store: ChatHistoryStore
    let onContinue: (ConversationRecord) -> Void

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { navigation.section },
                set: { if let value = $0 { navigation.section = value } }
            )) {
                Label("Разговоры", systemImage: "bubble.left.and.bubble.right")
                    .tag(MainWindowController.Section.history)
                Section("Настройки") {
                    Label("Разрешения", systemImage: "hand.raised")
                        .tag(MainWindowController.Section.permissions)
                    Label("Лимит подписки", systemImage: "gauge.with.dots.needle.33percent")
                        .tag(MainWindowController.Section.usage)
                    Label("Общие", systemImage: "gearshape")
                        .tag(MainWindowController.Section.general)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            switch navigation.section {
            case .history:
                HistoryView(session: session, store: store, onContinue: onContinue)
            case .permissions:
                PermissionsSettingsView(settings: settings)
            case .usage:
                UsageView(usage: session.timeline.usage)
            case .general:
                GeneralView()
            }
        }
    }
}
