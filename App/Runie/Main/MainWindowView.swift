import RunieKit
import SwiftUI

/// Слева — поиск и недавние разговоры, внизу закреплены «Настройки».
/// Справа — выбранный разговор или настройки.
struct MainWindowView: View {
    @Bindable var navigation: MainNavigation
    let session: ChatSession
    let settings: AppSettings
    let store: ChatHistoryStore
    let onContinue: (ConversationRecord) -> Void

    @State private var records: [ConversationRecord] = []
    @State private var query = ""
    @State private var pendingDelete: ConversationRecord?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            if navigation.section.isSettings {
                SettingsView(navigation: navigation, session: session, settings: settings)
            } else if let record = records.first(where: { $0.id == navigation.selectedConversation }) {
                ConversationDetail(
                    record: record,
                    session: session,
                    settings: settings,
                    onContinueAtOrb: onContinue,
                    onDelete: { pendingDelete = record }
                )
            } else if navigation.selectedConversation == session.conversationID {
                // Новый разговор: в истории его ещё нет, появится с первым сообщением.
                ConversationDetail(record: nil, session: session, settings: settings, onContinueAtOrb: onContinue, onDelete: {})
            } else {
                BrandEmptyState(
                    title: records.isEmpty ? "Разговоров пока нет" : "Выберите разговор",
                    subtitle: records.isEmpty
                        ? "Нажмите на орб или ⌘N и напишите Руни — разговор появится здесь."
                        : "Слева — недавние разговоры."
                )
                .background(BrandGlowBackground())
            }
        }
        // Фирменный бирюзовый — выделение, переключатели, кнопки.
        .tint(OrbPalette.teal)
        .onAppear(perform: reload)
        .onChange(of: session.historyRevision) { reload() }
        .confirmationDialog(
            "Удалить разговор?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { record in
            Button("Удалить", role: .destructive) { delete(record) }
        } message: { record in
            Text("«\(record.title)» пропадёт из истории Runie.")
        }
    }

    // MARK: Боковая панель

    private var sidebar: some View {
        List(selection: Binding(
            get: { navigation.section.isSettings ? nil : navigation.selectedConversation },
            set: { id in
                guard let id else { return }
                navigation.selectedConversation = id
                navigation.section = .history
            }
        )) {
            Section("Недавние") {
                ForEach(filtered) { record in
                    SidebarConversationRow(record: record, isCurrent: record.id == session.conversationID)
                        .tag(record.id)
                        .contextMenu {
                            Button("Продолжить в Руни") { onContinue(record) }
                            Button("Удалить…", role: .destructive) { pendingDelete = record }
                        }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SidebarBrandHeader(session: session)
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Поиск по разговорам")
        .toolbar {
            ToolbarItem {
                Button(action: startNewConversation) {
                    Label("Новый разговор", systemImage: "square.and.pencil")
                }
                .help("Новый разговор (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
                .disabled(session.isBusy)
            }
        }
        .overlay {
            if !query.isEmpty, filtered.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        // Настройки закреплены внизу и не уезжают вместе со списком.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                SettingsButton(isSelected: navigation.section.isSettings) {
                    if !navigation.section.isSettings {
                        navigation.section = navigation.lastSettingsTab
                    }
                }
                .padding(10)
            }
        }
    }

    private var filtered: [ConversationRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return records }
        return records.filter { record in
            record.title.localizedCaseInsensitiveContains(trimmed)
                || record.items.contains { item in
                    switch item {
                    case .user(let user): user.text.localizedCaseInsensitiveContains(trimmed)
                    case .assistant(let reply): reply.text.localizedCaseInsensitiveContains(trimmed)
                    default: false
                    }
                }
        }
    }

    private func startNewConversation() {
        guard !session.isBusy else { return }
        if !session.timeline.items.isEmpty {
            session.startOver()
        }
        navigation.selectedConversation = session.conversationID
        navigation.section = .history
    }

    private func reload() {
        records = store.list()
        // Новый, ещё не сохранённый разговор — тоже законный выбор.
        if navigation.selectedConversation != session.conversationID,
           !records.contains(where: { $0.id == navigation.selectedConversation }) {
            navigation.selectedConversation = records.first?.id
        }
    }

    private func delete(_ record: ConversationRecord) {
        try? store.delete(record.id)
        if session.conversationID == record.id {
            session.startOver()
        }
        pendingDelete = nil
        reload()
    }
}

private struct SidebarConversationRow: View {
    let record: ConversationRecord
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(record.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if isCurrent {
                    Circle()
                        .fill(OrbPalette.teal)
                        .frame(width: 6, height: 6)
                        .help("Этот разговор сейчас в чате у орба")
                }
            }
            Text(record.updatedAt.formatted(.relative(presentation: .named).locale(.runie)))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct SettingsButton: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Настройки", systemImage: "gearshape")
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(isSelected ? AnyShapeStyle(.selection.opacity(0.25)) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(",", modifiers: .command)
        .help("Настройки Runie (⌘,)")
    }
}

/// Настройки: вкладки сверху, содержимое под ними.
private struct SettingsView: View {
    @Bindable var navigation: MainNavigation
    let session: ChatSession
    let settings: AppSettings

    var body: some View {
        Group {
            switch navigation.section {
            case .usage: UsageView(usage: session.timeline.usage)
            case .general: GeneralView()
            default: PermissionsSettingsView(settings: settings)
            }
        }
        .navigationTitle("Настройки")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Раздел", selection: Binding(
                    get: { navigation.section },
                    set: { navigation.section = $0 }
                )) {
                    Text("Разрешения").tag(MainWindowController.Section.permissions)
                    Text("Лимит подписки").tag(MainWindowController.Section.usage)
                    Text("Общие").tag(MainWindowController.Section.general)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}
