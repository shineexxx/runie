import RunieKit
import SwiftUI

/// Чат без подложки, как у Eney: отдельные стеклянные блоки над рабочим столом.
///
/// Снизу вверх: подсказки, поле ввода с кнопкой «развернуть», над ними — текущие
/// «руки» и пузырь с последним ответом. «Развернуть» заменяет пузырь всей перепиской.
/// Блоки прижаты к стороне, где стоит орб.
struct ChatView: View {

    let session: ChatSession
    let layout: ChatLayout
    let onClose: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            VStack(alignment: horizontalAlignment, spacing: ChatPanelController.blockSpacing) {
                Spacer(minLength: 0)

                if layout.isExpanded {
                    ConversationPanel(session: session, onCollapse: collapse)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
                } else {
                    CompactFeed(session: session, alignment: horizontalAlignment)
                        .transition(.opacity)
                }

                InputRow(session: session, layout: layout, onToggleExpanded: toggleExpanded)
                    .frame(height: ChatPanelController.inputHeight)

                ChipsRow(session: session, alignment: frameAlignment)
                    .frame(height: ChatPanelController.chipsHeight)
            }
            // Поля шире тени блоков, иначе край окна её обрезает.
            .padding(.horizontal, ChatPanelController.shadowMargin)
            .padding(.bottom, ChatPanelController.bottomInset)
            .frame(width: ChatPanelController.size.width)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    private var horizontalAlignment: HorizontalAlignment {
        layout.orbSide == .trailing ? .trailing : .leading
    }

    private var frameAlignment: Alignment {
        layout.orbSide == .trailing ? .trailing : .leading
    }

    private func toggleExpanded() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            layout.isExpanded.toggle()
        }
    }

    private func collapse() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            layout.isExpanded = false
        }
    }
}

// MARK: - Текущий ход

/// Всё, что случилось после последнего сообщения пользователя.
private struct CurrentTurn {
    let lastAction: ActionItem?
    let lastAssistantText: String?
    let lastNotice: NoticeItem?

    init(_ items: [TimelineItem]) {
        let start = (items.lastIndex { if case .user = $0 { true } else { false } }).map { $0 + 1 } ?? 0
        var action: ActionItem?
        var text: String?
        var notice: NoticeItem?
        for item in items[start...] {
            switch item {
            case .action(let value): action = value
            case .assistant(let value): text = value.text
            case .notice(let value): notice = value
            case .user: break
            }
        }
        lastAction = action
        lastAssistantText = text
        lastNotice = notice
    }
}

// MARK: - Компактная лента

private struct CompactFeed: View {
    let session: ChatSession
    let alignment: HorizontalAlignment

    var body: some View {
        let timeline = session.timeline
        let turn = CurrentTurn(timeline.items)

        VStack(alignment: alignment, spacing: 8) {
            if let action = turn.lastAction, showsAction(action) {
                ActionCapsule(action: action)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if let notice = turn.lastNotice, notice.kind == .error {
                Bubble { Text(notice.text).foregroundStyle(.red) }
            } else if let text = turn.lastAssistantText {
                Bubble { AssistantText(text: text) }
            } else if timeline.isBusy {
                Bubble {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(ActivityLabel.text(timeline.activity))
                            .foregroundStyle(.secondary)
                    }
                }
            } else if timeline.items.isEmpty {
                Bubble { Text("Чем помочь?") }
            } else if let notice = turn.lastNotice {
                Bubble { Text(notice.text).foregroundStyle(.secondary) }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: turn.lastAction?.id)
    }

    /// «Руки» видны, пока агент работает, или если последнее действие не удалось.
    private func showsAction(_ action: ActionItem) -> Bool {
        session.isBusy || action.status == .denied || action.status == .failed
    }
}

private struct Bubble<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.system(size: 14, weight: .medium))
            .textSelection(.enabled)
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .frame(maxWidth: 360, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .readableSurface(RoundedRectangle(cornerRadius: 24))
    }
}

/// Ответ помещается в пузырь целиком, а длинный — прокручивается и держится
/// у последней строки, пока печатается.
private struct AssistantText: View {
    let text: String

    var body: some View {
        ViewThatFits(in: .vertical) {
            label
            ScrollView {
                label.frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.bottom)
        }
        .frame(maxHeight: 280)
    }

    private var label: some View {
        Text(MarkdownText.inline(text))
            // Полужирный пузыря хорош для коротких реплик, а в абзаце тяжелит.
            .fontWeight(.regular)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ActionCapsule: View {
    let action: ActionItem

    var body: some View {
        HStack(spacing: 8) {
            ActionStatusIcon(status: action.status)
                .frame(width: 14)
            Text(action.title)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .frame(maxWidth: 320)
        .fixedSize(horizontal: true, vertical: false)
        .readableSurface(Capsule())
    }
}

// MARK: - Поле ввода

private struct InputRow: View {
    let session: ChatSession
    let layout: ChatLayout
    let onToggleExpanded: () -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Кнопка «развернуть» с дальней от орба стороны, как у Eney.
            if layout.orbSide == .trailing { expandButton }
            inputPill
            if layout.orbSide == .leading { expandButton }
        }
        .onAppear { isFocused = true }
        .onChange(of: layout.focusGeneration) { isFocused = true }
    }

    private var inputPill: some View {
        HStack(spacing: 8) {
            TextField("Опишите задачу…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...3)
                .focused($isFocused)
                .onSubmit(send)

            if session.isBusy {
                CircleIconButton(symbol: "stop.fill", tint: nil, help: "Остановить", action: session.stop)
            } else {
                CircleIconButton(
                    symbol: "arrow.up",
                    tint: trimmedDraft.isEmpty ? nil : OrbPalette.teal,
                    help: "Отправить (Return)",
                    action: send
                )
                .disabled(trimmedDraft.isEmpty)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 7)
        .frame(maxWidth: .infinity)
        .frame(height: ChatPanelController.inputHeight)
        .readableSurface(Capsule(), interactive: true)
    }

    private var expandButton: some View {
        Button(action: onToggleExpanded) {
            Image(systemName: layout.isExpanded
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .readableSurface(Circle(), interactive: true)
        .help(layout.isExpanded ? "Свернуть переписку" : "Вся переписка")
        .accessibilityLabel(layout.isExpanded ? "Свернуть переписку" : "Вся переписка")
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

private struct CircleIconButton: View {
    let symbol: String
    let tint: Color?
    let help: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
                .frame(width: 36, height: 36)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(glass, in: .circle)
        .opacity(isEnabled ? 1 : 0.45)
        .help(help)
        .accessibilityLabel(help)
    }

    private var glass: Glass {
        if let tint { return .regular.tint(tint).interactive() }
        return .regular.interactive()
    }
}

// MARK: - Подсказки

private struct ChipsRow: View {
    let session: ChatSession
    let alignment: Alignment

    private let suggestions = [
        "Календарь на сегодня",
        "Вчерашние скриншоты"
    ]

    var body: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    session.startOver()
                }
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .readableSurface(Circle(), interactive: true)
            .disabled(session.timeline.items.isEmpty)
            .opacity(session.timeline.items.isEmpty ? 0.45 : 1)
            .help("Новый разговор")
            .accessibilityLabel("Новый разговор")

            if session.timeline.items.isEmpty {
                ForEach(suggestions, id: \.self) { suggestion in
                    Chip(title: suggestion) { session.send(suggestion) }
                }
            } else if let usage = session.timeline.usage {
                UsageChip(usage: usage)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }
}

private struct Chip: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 13)
                .frame(height: 32)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .readableSurface(Capsule(), interactive: true)
    }
}

/// Остаток подписки за пять часов. Цифра приходит из потока агента сама.
private struct UsageChip: View {
    let usage: SubscriptionUsage

    var body: some View {
        if let window = usage.window("five_hour") {
            Text("\(Int((window.utilization * 100).rounded()))%")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(window.utilization >= 0.8 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 11)
                .frame(height: 32)
                .readableSurface(Capsule())
                .help(UsageChip.tooltip(usage))
        }
    }

    static func tooltip(_ usage: SubscriptionUsage) -> String {
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

// MARK: - Развёрнутая переписка

private struct ConversationPanel: View {
    let session: ChatSession
    let onCollapse: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if session.isBusy {
                    ProgressView().controlSize(.mini)
                }
                Text(session.isBusy ? ActivityLabel.text(session.timeline.activity) : "Переписка")
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(action: onCollapse) {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .help("Свернуть (Esc)")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 6)

            if session.timeline.items.isEmpty {
                Text("Пока пусто")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ConversationList(timeline: session.timeline)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .readableSurface(RoundedRectangle(cornerRadius: 26))
    }
}

private struct ConversationList: View {
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
                // при потоковом выводе это десятки обновлений в секунду.
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

// MARK: - Общее

private extension View {
    /// Поверхность блока — стекло, тонированное так, чтобы оставаться читаемым.
    ///
    /// Чистое `regular`-стекло над плотным текстом пропускает строки под собой.
    /// В SDK всего два вида стекла, `regular` и `clear`, поэтому читаемость
    /// даёт тонировка внутри самого стекла: так делает Spotlight. Непрозрачная
    /// заливка поверх стекла тоже читается, но убивает само стекло.
    func readableSurface<S: InsettableShape>(_ shape: S, interactive: Bool = false) -> some View {
        let glass = Glass.regular.tint(SurfaceTint.color)
        return glassEffect(interactive ? glass.interactive() : glass, in: shape)
            .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
    }
}

/// Тонировка стекла. Светлая в светлой теме, тёмная в тёмной.
enum SurfaceTint {
    static var color: Color {
        let strength = level
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(white: 0.08, alpha: strength * 0.8)
                : NSColor(white: 1.0, alpha: strength)
        })
    }

    private static var level: CGFloat {
        #if DEBUG
        // Для подбора на экране: `-RunieSurface 0.6` в аргументах запуска.
        // 0.35 выбрано сравнением на экране: ближе всего к Spotlight. При 0.6
        // белая тонировка внутри стекла уже даёт серый, а не белёсый блок.
        let forced = UserDefaults.standard.double(forKey: "RunieSurface")
        if forced > 0 { return CGFloat(forced) }
        #endif
        return 0.35
    }
}

enum ActivityLabel {
    static func text(_ activity: ChatTimeline.Activity) -> String {
        switch activity {
        case .idle: "Руни"
        case .waiting: "Отправляю…"
        case .thinking: "Думает…"
        case .working(let detail): detail ?? "Работает…"
        case .responding: "Отвечает…"
        }
    }
}

enum MarkdownText {
    /// Жирный, курсив, код и ссылки в строке. Блочную разметку — заголовки, списки —
    /// показываем как есть: лучше честный текст, чем сломанная вёрстка.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
