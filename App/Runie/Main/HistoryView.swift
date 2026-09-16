import RunieKit
import SwiftUI

/// Разговор в окне Runie: переписка и поле ввода — продолжать можно прямо здесь.
///
/// Чат у орба и окно — один и тот же разговор с агентом. Если выбранный разговор
/// сейчас не в работе, первое сообщение открывает его и продолжает его сессию.
struct ConversationDetail: View {
    /// Сохранённый разговор. `nil` — новый, ещё не начатый.
    let record: ConversationRecord?
    let session: ChatSession
    let settings: AppSettings
    let onContinueAtOrb: (ConversationRecord) -> Void
    let onDelete: () -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    /// Этот разговор сейчас в сессии: показываем живую ленту, а не снимок из файла.
    private var isLive: Bool {
        record == nil || record?.id == session.conversationID
    }

    private var items: [TimelineItem] {
        isLive ? session.timeline.items : (record?.items ?? [])
    }

    /// Агент занят другим разговором — этот продолжить нельзя, не оборвав тот.
    private var isBlockedByOther: Bool {
        !isLive && session.isBusy
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            composerArea
        }
        .background(BrandGlowBackground())
        .navigationTitle(record?.title ?? "Новый разговор")
        .toolbar {
            if let record {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        onContinueAtOrb(record)
                    } label: {
                        Label("Открыть у орба", systemImage: "circle.circle")
                    }
                    .help("Продолжить этот разговор в чате у орба")
                    Button(role: .destructive, action: onDelete) {
                        Label("Удалить", systemImage: "trash")
                    }
                    .help("Удалить разговор")
                }
            }
        }
        .onAppear { isFocused = true }
    }

    // MARK: Переписка

    @ViewBuilder
    private var transcript: some View {
        if items.isEmpty {
            BrandEmptyState(
                title: SuggestionSet.fallbackGreeting(),
                subtitle: "Напишите Руни внизу — ответ появится здесь."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(items) { item in
                        TimelineRow(item: item)
                    }
                    if isLive, session.isBusy, session.pendingPermission == nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(ActivityLabel.text(session.timeline.activity))
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 8)
                    }
                }
                .padding(24)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            // Держимся у последней строки и при первом показе, и пока ответ печатается.
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .id(record?.id)
        }
    }

    // MARK: Поле ввода

    private var composerArea: some View {
        VStack(spacing: 10) {
            if isLive, let request = session.pendingPermission {
                PermissionCard(request: request, session: session)
                    .id(request.requestID)
            }

            if isBlockedByOther {
                Label("Руни сейчас занят другим разговором. Дождитесь ответа или остановите его.",
                      systemImage: "hourglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...8)
                    .focused($isFocused)
                    .onSubmit(send)
                    .disabled(isBlockedByOther)
                    .padding(.vertical, 8)

                ModelMenu(session: session, settings: settings, compact: false)
                    .padding(.bottom, 5)
                sendButton
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .padding(.vertical, 4)
            // Стекло с бирюзовым оттенком, как блоки чата у орба; в фокусе — светящийся край.
            .glassEffect(.regular.tint(OrbPalette.teal.opacity(0.10)), in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(
                        isFocused
                            ? AnyShapeStyle(LinearGradient(colors: [OrbPalette.cyan.opacity(0.7), OrbPalette.azure.opacity(0.5)],
                                                           startPoint: .topLeading, endPoint: .bottomTrailing))
                            : AnyShapeStyle(.separator),
                        lineWidth: isFocused ? 1.5 : 1
                    )
            }
            .shadow(color: OrbPalette.teal.opacity(isFocused ? 0.25 : 0), radius: 14)
            .animation(.easeOut(duration: 0.2), value: isFocused)
        }
        .frame(maxWidth: 720)
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
    }

    private var placeholder: String {
        if isLive, session.isBusy { return "Руни работает…" }
        return record == nil ? "Напишите Руни…" : "Продолжить разговор…"
    }

    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sendButton: some View {
        let busy = isLive && session.isBusy
        let enabled = busy || (hasDraft && !isBlockedByOther)
        return Button(action: busy ? { session.stop() } : send) {
            Image(systemName: busy ? "stop.fill" : "arrow.up")
                .font(.system(size: busy ? 12 : 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(OrbPalette.deep.gradient))
                .opacity(enabled ? 1 : 0.35)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .padding(.bottom, 2)
        .help(busy ? "Остановить" : "Отправить")
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !session.isBusy else { return }
        if let record, record.id != session.conversationID {
            session.open(record)
        }
        draft = ""
        session.send(text)
    }
}
