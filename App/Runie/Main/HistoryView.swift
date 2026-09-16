import RunieKit
import SwiftUI

/// Все разговоры с Руни: слева список, справа переписка.
struct HistoryView: View {
    @Bindable var navigation: MainNavigation
    let session: ChatSession
    let store: ChatHistoryStore
    let onContinue: (ConversationRecord) -> Void

    @State private var records: [ConversationRecord] = []
    @State private var query = ""
    @State private var pendingDelete: ConversationRecord?

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            detail
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Разговоры")
        .searchable(text: $query, placement: .toolbar, prompt: "Поиск по разговорам")
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

    @ViewBuilder
    private var list: some View {
        if records.isEmpty {
            ContentUnavailableView(
                "Разговоров пока нет",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Нажмите на орб и напишите Руни — разговор появится здесь.")
            )
        } else {
            List(filtered, selection: $navigation.selectedConversation) { record in
                ConversationListRow(record: record, isCurrent: record.id == session.conversationID)
                    .tag(record.id)
                    .contextMenu {
                        Button("Продолжить в Руни") { onContinue(record) }
                        Button("Удалить…", role: .destructive) { pendingDelete = record }
                    }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let record = records.first(where: { $0.id == navigation.selectedConversation }) {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(record.items) { item in
                            TimelineRow(item: item)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom)

                Divider()
                HStack {
                    Text(record.updatedAt.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(.runie)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Удалить…", role: .destructive) { pendingDelete = record }
                    Button("Продолжить в Руни") { onContinue(record) }
                        .buttonStyle(.borderedProminent)
                        .tint(OrbPalette.deep)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        } else {
            ContentUnavailableView("Выберите разговор", systemImage: "text.bubble")
        }
    }

    private func reload() {
        records = store.list()
        if !records.contains(where: { $0.id == navigation.selectedConversation }) {
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

private struct ConversationListRow: View {
    let record: ConversationRecord
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(record.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if isCurrent {
                    Text("сейчас")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(OrbPalette.teal)
                }
            }
            if let preview = record.preview {
                Text(preview)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(record.updatedAt.formatted(.relative(presentation: .named).locale(.runie)))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
