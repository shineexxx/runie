import RunieKit
import SwiftUI

/// Минималистичный чат в стиле Liquid Glass.
struct ChatView: View {

    let session: ChatSession
    let focus: ChatFocusRequest
    let onClose: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 0) {
                ChatHeader(session: session, onClose: onClose)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 8)

                if session.timeline.items.isEmpty {
                    EmptyChat(onPick: session.send)
                        .frame(maxHeight: .infinity)
                } else {
                    TimelineView(timeline: session.timeline)
                }

                Composer(session: session, focus: focus)
                    .padding(12)
            }
            .frame(width: ChatPanelController.size.width, height: ChatPanelController.size.height)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
        }
    }
}

// MARK: - Шапка

private struct ChatHeader: View {
    let session: ChatSession
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            StatusIndicator(activity: session.timeline.activity)

            Spacer(minLength: 8)

            if let usage = session.timeline.usage {
                UsageChip(usage: usage)
            }

            Button {
                session.startOver()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .help("Новый разговор")
            .disabled(session.timeline.items.isEmpty)

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Закрыть (Esc)")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
    }
}

private struct StatusIndicator: View {
    let activity: ChatTimeline.Activity

    var body: some View {
        HStack(spacing: 6) {
            if activity == .idle {
                Circle()
                    .fill(.green.opacity(0.8))
                    .frame(width: 6, height: 6)
            } else {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(label)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: label)
        }
    }

    private var label: String {
        switch activity {
        case .idle: "Runie"
        case .waiting: "Отправляю…"
        case .thinking: "Думает…"
        case .working(let detail): detail ?? "Работает…"
        case .responding: "Отвечает…"
        }
    }
}

/// Остаток подписки за пять часов. Отдельный счётчик не нужен: цифра приходит
/// из потока агента сама.
private struct UsageChip: View {
    let usage: SubscriptionUsage

    var body: some View {
        if let window = usage.window("five_hour") {
            Text("\(Int((window.utilization * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(window.utilization >= 0.8 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary.opacity(0.5), in: .capsule)
                .help(tooltip)
        }
    }

    private var tooltip: String {
        let parts = usage.windows.map { window in
            let name = switch window.kind {
            case "five_hour": "за 5 часов"
            case "seven_day": "за 7 дней"
            default: window.kind
            }
            return "\(name): \(Int((window.utilization * 100).rounded()))%"
        }
        return "Использовано подписки — " + parts.joined(separator: ", ")
    }
}

// MARK: - Пустой чат

private struct EmptyChat: View {
    let onPick: (String) -> Void

    private let suggestions = [
        "Что у меня сегодня в календаре?",
        "Найди вчерашние скриншоты",
        "Сколько свободного места на диске?"
    ]

    var body: some View {
        VStack(spacing: 18) {
            Text("Чем помочь?")
                .font(.system(size: 22, weight: .semibold, design: .rounded))

            VStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        onPick(suggestion)
                    } label: {
                        Text(suggestion)
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 28)
        }
    }
}

// MARK: - Лента

private struct TimelineView: View {
    let timeline: ChatTimeline

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(timeline.items) { item in
                        TimelineRow(item: item)
                            .id(item.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .onChange(of: timeline.items) { old, items in
                guard let last = items.last else { return }
                // Новая реплика въезжает плавно. Дописывание текущей — без анимации:
                // при потоковом выводе это десятки обновлений в секунду, и анимация
                // на каждое превращает прокрутку в дрожь.
                if old.last?.id == last.id {
                    proxy.scrollTo(last.id, anchor: .bottom)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                if let last = timeline.items.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - Поле ввода

private struct Composer: View {
    let session: ChatSession
    let focus: ChatFocusRequest

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Попросите Runie…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...6)
                .focused($isFocused)
                .onSubmit(send)
                .padding(.vertical, 6)

            if session.isBusy {
                Button(action: session.stop) {
                    Image(systemName: "stop.fill")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.glass)
                .help("Остановить")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .fontWeight(.semibold)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.glass)
                .disabled(trimmedDraft.isEmpty)
                .help("Отправить (Return)")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .onAppear { isFocused = true }
        .onChange(of: focus.generation) { isFocused = true }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send() {
        guard !trimmedDraft.isEmpty, !session.isBusy else { return }
        session.send(draft)
        draft = ""
    }
}
