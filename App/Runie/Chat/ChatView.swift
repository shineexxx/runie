import RunieKit
import SwiftUI

/// Чат без подложки, как у Eney: отдельные стеклянные блоки над рабочим столом.
///
/// Снизу вверх: подсказки, поле ввода с кнопкой «развернуть», над ними — текущие
/// «руки» и пузырь с последним ответом. «Развернуть» заменяет пузырь всей перепиской.
/// Блоки прижаты к стороне, где стоит орб.
struct ChatView: View {

    let session: ChatSession
    let settings: AppSettings
    let layout: ChatLayout
    let tracker: FrontmostAppTracker
    let onSend: (String) -> Void
    let onClose: () -> Void
    /// Открыть окно Runie на этом разговоре.
    let onOpenWindow: () -> Void

    /// Когда началось появление. Ход считается от этого времени внутри `TimelineView`,
    /// а не интерполяцией SwiftUI: свечение на Canvas при анимируемом значении
    /// не перерисовывалось, и блоки просто оказывались на месте.
    @State private var emergenceStart = Date.distantPast
    @State private var isEmerging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Сколько длится появление. Первые мгновения совпадают с уходом света из орба.
    private static var emergenceDuration: Double {
        #if DEBUG
        // Для разглядывания по кадрам: `-RunieEmergeDuration 6` в аргументах запуска.
        let forced = UserDefaults.standard.double(forKey: "RunieEmergeDuration")
        if forced > 0 { return forced }
        #endif
        return 0.75
    }

    var body: some View {
        TimelineView(.animation(paused: !isEmerging)) { timeline in
            content(emergence: emergenceProgress(at: timeline.date))
        }
        .onAppear(perform: emerge)
        .onChange(of: layout.openGeneration) { emerge() }
    }

    private func content(emergence: Double) -> some View {
        ZStack(alignment: .bottom) {
            // Свет, пришедший из орба. Лежит под блоками: они проступают из него.
            GeometryReader { proxy in
                EmergenceGlow(
                    progress: emergence,
                    origin: orbPoint(in: proxy.size),
                    targets: glowTargets(in: proxy.size)
                )
            }
            .allowsHitTesting(false)

            // Без GlassEffectContainer: он рисует стекло детей отдельным проходом
            // и игнорирует их прозрачность и масштаб — блоки не проступали бы из света.
            do {
                VStack(alignment: horizontalAlignment, spacing: ChatPanelController.blockSpacing) {
                    Spacer(minLength: 0)

                    CompactFeed(session: session, alignment: horizontalAlignment)
                        .modifier(EmergeFromLight(progress: emergence, window: 0.34...0.82, anchor: orbCornerAnchor))

                    // Агент стоит и ждёт ответа — вопрос прямо над полем ввода.
                    if let request = session.pendingPermission {
                        PermissionCard(request: request, session: session)
                            .id(request.requestID)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: orbCornerAnchor)))
                    }

                    InputRow(
                        session: session,
                        settings: settings,
                        layout: layout,
                        onSubmitDraft: submitDraft,
                        onStop: { session.stop() },
                        onOpenWindow: onOpenWindow
                    )
                    .frame(height: ChatPanelController.inputHeight)
                    // Поле первым вытягивается из света вдоль строки, от орба.
                    .modifier(EmergeFromLight(
                        progress: emergence,
                        window: 0.08...0.52,
                        anchor: orbAnchor,
                        stretchesHorizontally: true
                    ))

                    ChipsRow(
                        session: session,
                        suggestions: tracker.current?.context.suggestions ?? ContextSuggestions.fallback,
                        alignment: frameAlignment,
                        onSend: onSend
                    )
                    .frame(height: ChatPanelController.chipsHeight)
                    .modifier(EmergeFromLight(progress: emergence, window: 0.26...0.72, anchor: orbCornerAnchor))
                }
                // Поля шире тени блоков, иначе край окна её обрезает.
                .padding(.horizontal, ChatPanelController.shadowMargin)
                .padding(.bottom, ChatPanelController.bottomInset)
                .frame(width: ChatPanelController.size.width)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    /// Ход появления от 0 до 1 с замедлением к концу.
    private func emergenceProgress(at date: Date) -> Double {
        let raw = date.timeIntervalSince(emergenceStart) / Self.emergenceDuration
        let t = min(max(raw, 0), 1)
        return 1 - pow(1 - t, 3)
    }

    // MARK: Геометрия света

    /// Центр орба в координатах окна: он стоит за ближним концом поля ввода.
    private func orbPoint(in size: CGSize) -> CGPoint {
        let fromEdge = ChatPanelController.shadowMargin - ChatPanelController.orbGap
        let x = layout.orbSide == .trailing ? size.width - fromEdge : fromEdge
        return CGPoint(x: x, y: size.height - inputCenterFromBottom)
    }

    /// Куда растекается свет: вдоль поля, к подсказкам и к месту ответа.
    private func glowTargets(in size: CGSize) -> [CGPoint] {
        let origin = orbPoint(in: size)
        let direction: CGFloat = layout.orbSide == .trailing ? -1 : 1
        let rowWidth = size.width - ChatPanelController.shadowMargin * 2
        let inputY = origin.y
        let chipsY = size.height - ChatPanelController.bottomInset - ChatPanelController.chipsHeight / 2
        let bubbleY = inputY - ChatPanelController.inputHeight / 2 - ChatPanelController.blockSpacing - 40
        return [
            CGPoint(x: origin.x + direction * rowWidth * 0.45, y: inputY),
            CGPoint(x: origin.x + direction * rowWidth * 0.85, y: inputY),
            CGPoint(x: origin.x + direction * rowWidth * 0.35, y: chipsY),
            CGPoint(x: origin.x + direction * rowWidth * 0.2, y: bubbleY)
        ]
    }

    private var inputCenterFromBottom: CGFloat {
        ChatPanelController.bottomInset
            + ChatPanelController.chipsHeight
            + ChatPanelController.blockSpacing
            + ChatPanelController.inputHeight / 2
    }

    // MARK: Выравнивание

    private var horizontalAlignment: HorizontalAlignment {
        layout.orbSide == .trailing ? .trailing : .leading
    }

    private var frameAlignment: Alignment {
        layout.orbSide == .trailing ? .trailing : .leading
    }

    private var orbAnchor: UnitPoint {
        layout.orbSide == .trailing ? .trailing : .leading
    }

    /// Нижний угол блоков со стороны орба: блоки вырастают из того места, откуда пришёл свет.
    private var orbCornerAnchor: UnitPoint {
        layout.orbSide == .trailing ? .bottomTrailing : .bottomLeading
    }

    // MARK: Действия

    private func emerge() {
        guard !reduceMotion else {
            emergenceStart = .distantPast
            return
        }
        let start = Date()
        emergenceStart = start
        isEmerging = true
        let duration = Self.emergenceDuration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration + 0.1))
            // Если чат успели открыть заново, этот запуск уже не главный.
            if emergenceStart == start { isEmerging = false }
        }
    }

    private func submitDraft() {
        guard layout.hasDraft, !session.isBusy else { return }
        let text = layout.draft
        layout.draft = ""
        onSend(text)
    }

}

// MARK: - Появление из света

/// Бирюзовое свечение, которое вылетает из орба и растекается по месту блоков.
///
/// Пятна те же, что внутри орба, и выходят из той же точки: для глаза это
/// продолжение света, который только что покинул шар. Ярче всего свет посередине
/// пути — в этот момент из него проступают блоки, — и гаснет, когда они на месте.
private struct EmergenceGlow: View {

    let progress: Double
    let origin: CGPoint
    let targets: [CGPoint]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let colors = [OrbPalette.cyan, OrbPalette.teal, OrbPalette.azure, OrbPalette.mint]

    var body: some View {
        Canvas { context, canvasSize in
            guard !reduceMotion, progress > 0.001, progress < 0.999 else { return }
            let blur: CGFloat = 22
            context.addFilter(.blur(radius: blur))
            context.blendMode = .plusLighter

            // Рост быстрый, угасание долгое: свет вспыхивает и медленно тает.
            let brightness = sin(min(progress / 0.7, 1) * .pi) * (1 - max(0, progress - 0.7) / 0.3)
            let travel = 1 - pow(1 - progress, 3)

            for (index, target) in targets.enumerated() {
                // Пятна отстают друг от друга, поэтому свет течёт, а не прыгает.
                let lag = Double(index) * 0.08
                let t = max(0, min(1, (travel - lag) / (1 - lag)))
                let point = CGPoint(
                    x: origin.x + (target.x - origin.x) * t,
                    y: origin.y + (target.y - origin.y) * t
                )
                // Пятно вместе с хвостом размытия не должно доходить до края окна,
                // иначе край срежет свет прямой линией.
                let room = min(point.x, canvasSize.width - point.x, point.y, canvasSize.height - point.y) - blur * 1.6
                let radius = max(6, min(22 + 58 * t, room))
                let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                let color = Self.colors[index % Self.colors.count]
                context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.75 * brightness)))
            }
        }
    }
}

/// Блок проступает из света в своё окно времени: сначала бледный и сжатый к орбу,
/// потом яркий и на месте. Окна у блоков разные — ближние к орбу появляются раньше.
private struct EmergeFromLight: ViewModifier {

    let progress: Double
    let window: ClosedRange<Double>
    let anchor: UnitPoint
    var stretchesHorizontally = false

    func body(content: Content) -> some View {
        let raw = (progress - window.lowerBound) / (window.upperBound - window.lowerBound)
        let reveal = max(0, min(1, raw))
        // Плавный вход и выход вместо линейного.
        let eased = reveal * reveal * (3 - 2 * reveal)

        return content
            .opacity(eased)
            .brightness((1 - eased) * 0.35)
            .scaleEffect(
                x: stretchesHorizontally ? 0.12 + 0.88 * eased : 0.82 + 0.18 * eased,
                y: stretchesHorizontally ? 0.7 + 0.3 * eased : 0.82 + 0.18 * eased,
                anchor: anchor
            )
    }
}

// MARK: - Текущий ход

/// Последнее сообщение пользователя и всё, что случилось после него.
private struct CurrentTurn {
    let userText: String?
    let lastAction: ActionItem?
    let lastAssistantText: String?
    let lastNotice: NoticeItem?

    init(_ items: [TimelineItem]) {
        let userIndex = items.lastIndex { if case .user = $0 { true } else { false } }
        if let userIndex, case .user(let user) = items[userIndex] {
            userText = user.text
        } else {
            userText = nil
        }
        let start = userIndex.map { $0 + 1 } ?? 0
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

        // Пока висит вопрос о разрешении, всё про текущее действие уже в карточке.
        let asking = session.pendingPermission != nil

        // Как в мессенджере: моё сообщение справа, Руни отвечает слева.
        VStack(alignment: .leading, spacing: 8) {
            if let userText = turn.userText {
                UserMessageBubble(text: userText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if let action = turn.lastAction, showsAction(action), !asking {
                ActionCapsule(action: action)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if let notice = turn.lastNotice, notice.kind == .error {
                Bubble(tail: tailEdge) { Text(notice.text).foregroundStyle(.red) }
            } else if let text = turn.lastAssistantText {
                Bubble(tail: tailEdge) { AssistantText(text: text) }
            } else if timeline.isBusy, !asking {
                Bubble(tail: tailEdge) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(ActivityLabel.text(timeline.activity))
                            .foregroundStyle(.secondary)
                    }
                }
            } else if timeline.items.isEmpty {
                Bubble(tail: tailEdge) { Text("Чем помочь?") }
            } else if let notice = turn.lastNotice {
                Bubble(tail: tailEdge) { Text(notice.text).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: turn.lastAction?.id)
    }

    /// Руни всегда отвечает слева.
    private let tailEdge: HorizontalEdge = .leading

    /// «Руки» видны, пока агент работает, или если последнее действие не удалось.
    private func showsAction(_ action: ActionItem) -> Bool {
        session.isBusy || action.status == .denied || action.status == .failed
    }
}

private struct Bubble<Content: View>: View {
    var tail: HorizontalEdge = .trailing
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.system(size: 14, weight: .medium))
            .textSelection(.enabled)
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .frame(maxWidth: 360, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .readableSurface(MessageBubbleShape(tail: tail))
            // Хвостик выходит за рамку пузыря — место под него.
            .padding(tail == .trailing ? .trailing : .leading, MessageBubbleShape.tailReach)
    }
}

/// Моё сообщение: бирюзовое облачко справа.
struct UserMessageBubble: View {
    let text: String
    var maxWidth: CGFloat = 300

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .lineLimit(4)
            .truncationMode(.tail)
            .textSelection(.enabled)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: maxWidth, alignment: .leading)
            // Сплошная заливка, а не стекло: бирюзовый оттенок стекла на тёмном фоне
            // уходит в серый, и своё сообщение не отличить от ответа.
            .background(OrbPalette.deep.gradient, in: MessageBubbleShape(tail: .trailing))
            .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
            .padding(.trailing, MessageBubbleShape.tailReach)
    }
}

/// Облачко сообщения: скруглённый блок с хвостиком в нижнем углу, как в Сообщениях.
struct MessageBubbleShape: InsettableShape {
    var tail: HorizontalEdge
    var inset: CGFloat = 0

    static let tailReach: CGFloat = 6
    private static let radius: CGFloat = 20

    func inset(by amount: CGFloat) -> MessageBubbleShape {
        var copy = self
        copy.inset += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let radius = min(Self.radius, r.height / 2)
        let reach = Self.tailReach

        // Рисуем с хвостиком справа, для левого отражаем.
        var path = Path()
        path.move(to: CGPoint(x: r.minX + radius, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
        path.addArc(center: CGPoint(x: r.maxX - radius, y: r.minY + radius), radius: radius,
                    startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        // Правый край спускается к хвостику и плавно вытягивается в остриё.
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius * 0.9))
        path.addQuadCurve(to: CGPoint(x: r.maxX + reach, y: r.maxY),
                          control: CGPoint(x: r.maxX, y: r.maxY - 2))
        path.addQuadCurve(to: CGPoint(x: r.maxX - radius * 0.75, y: r.maxY - 2),
                          control: CGPoint(x: r.maxX - 4, y: r.maxY + 1))
        path.addQuadCurve(to: CGPoint(x: r.maxX - radius * 1.1, y: r.maxY),
                          control: CGPoint(x: r.maxX - radius * 0.95, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        path.addArc(center: CGPoint(x: r.minX + radius, y: r.maxY - radius), radius: radius,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
        path.addArc(center: CGPoint(x: r.minX + radius, y: r.minY + radius), radius: radius,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()

        guard tail == .leading else { return path }
        return path.applying(CGAffineTransform(translationX: rect.minX + rect.maxX, y: 0).scaledBy(x: -1, y: 1))
    }
}

/// Ответ помещается в пузырь целиком, а длинный — прокручивается и держится
/// у последней строки, пока печатается.
private struct AssistantText: View {
    let text: String

    private static let maxHeight: CGFloat = 280

    /// Высота текста целиком. `ViewThatFits` для этого не годится: он сравнивает с
    /// высотой, которую предлагает стек, а та бывает меньше нужной, — и пузырь
    /// с коротким ответом раздувался до полной высоты прокрутки.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(contentHeight <= Self.maxHeight)
        .defaultScrollAnchor(.bottom)
        .frame(height: min(max(contentHeight, 1), Self.maxHeight))
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

// MARK: - Разрешение

/// Вопрос «можно?» перед действием, которое CLI сам не выполняет: команда, запись
/// файла, страница в интернете. Человек видит, что именно сделает Руни, и решает.
struct PermissionCard: View {
    let request: PermissionRequest
    let session: ChatSession

    var body: some View {
        let description = ToolDescriber.describe(name: request.toolName, input: request.input)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Руни просит разрешения", systemImage: "hand.raised.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OrbPalette.teal)
                Spacer(minLength: 8)
                // Группа — та же, что в настройках: там её можно разрешить заранее.
                Text(categoryNames)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(description.title)
                .font(.system(size: 14, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

            if let detail = description.detail {
                Text(detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }

            HStack(spacing: 8) {
                Button("Отклонить") { session.answer(request, allow: false) }
                    .buttonStyle(PermissionButtonStyle(kind: .plain))
                Spacer(minLength: 0)
                Button("Всегда") { session.answer(request, allow: true, remember: true) }
                    .buttonStyle(PermissionButtonStyle(kind: .secondary))
                    .help(alwaysHelp)
                Button("Разрешить") { session.answer(request, allow: true) }
                    .buttonStyle(PermissionButtonStyle(kind: .primary))
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
        .readableSurface(RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Руни просит разрешения: \(description.title)")
    }

    private var categoryNames: String {
        PermissionCategory.allCases
            .filter { PermissionClassifier.categories(for: request).contains($0) }
            .map(\.title)
            .joined(separator: ", ")
    }

    private var alwaysHelp: String {
        switch request.toolName {
        case "Bash": "Больше не спрашивать об этой команде до конца разговора"
        case "WebFetch": "Больше не спрашивать об этом сайте до конца разговора"
        default: "Больше не спрашивать о таком действии до конца разговора"
        }
    }
}

private struct PermissionButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, plain }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: kind == .primary ? .semibold : .medium))
            .foregroundStyle(kind == .primary ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background {
                switch kind {
                case .primary: Capsule().fill(OrbPalette.deep.gradient)
                case .secondary: Capsule().fill(.primary.opacity(0.08))
                case .plain: Color.clear
                }
            }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Поле ввода

private struct InputRow: View {
    let session: ChatSession
    let settings: AppSettings
    @Bindable var layout: ChatLayout
    let onSubmitDraft: () -> Void
    let onStop: () -> Void
    let onOpenWindow: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Кнопка «развернуть» с дальней от орба стороны.
            if layout.orbSide == .trailing { expandButton }
            inputPill
            if layout.orbSide == .leading { expandButton }
        }
        .onAppear { isFocused = true }
        .onChange(of: layout.focusGeneration) { isFocused = true }
    }

    /// Кнопка отправки — у ближнего к орбу конца поля, откуда пришёл свет.
    private var inputPill: some View {
        HStack(spacing: 10) {
            if layout.orbSide == .leading { sendButton }

            TextField(placeholder, text: $layout.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...3)
                .focused($isFocused)
                .onSubmit(onSubmitDraft)

            ModelMenu(session: session, settings: settings)
            if layout.orbSide == .trailing { sendButton }
        }
        .padding(.leading, layout.orbSide == .trailing ? 22 : 7)
        .padding(.trailing, layout.orbSide == .trailing ? 7 : 22)
        .frame(maxWidth: .infinity)
        .frame(height: ChatPanelController.inputHeight)
        .readableSurface(Capsule(), interactive: true)
    }

    /// Стрелка отправки, пока Руни свободен, и «стоп», пока работает.
    private var sendButton: some View {
        let busy = session.isBusy
        let enabled = busy || layout.hasDraft
        return Button(action: busy ? onStop : onSubmitDraft) {
            Image(systemName: busy ? "stop.fill" : "arrow.up")
                .font(.system(size: busy ? 13 : 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(Circle().fill(OrbPalette.deep.gradient))
                .opacity(enabled ? 1 : 0.35)
                .contentShape(.circle)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .animation(.easeOut(duration: 0.15), value: enabled)
        .help(busy ? "Остановить" : "Отправить")
        .accessibilityLabel(busy ? "Остановить" : "Отправить")
    }

    private var placeholder: String {
        session.isBusy ? "Руни работает…" : "Опишите задачу…"
    }

    private var expandButton: some View {
        Button(action: onOpenWindow) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .readableSurface(Circle(), interactive: true)
        .help("Открыть разговор в окне Runie")
        .accessibilityLabel("Открыть разговор в окне Runie")
    }
}

// MARK: - Контекст

/// Где человек сейчас. Клик выключает передачу контекста агенту.
// MARK: - Подсказки

private struct ChipsRow: View {
    let session: ChatSession
    let suggestions: [String]
    let alignment: Alignment
    let onSend: (String) -> Void

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
                    Chip(title: suggestion) { onSend(suggestion) }
                }
            } else if let usage = session.timeline.usage {
                UsageChip(usage: usage)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
        .animation(.easeOut(duration: 0.2), value: suggestions)
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

    /// Системная подсказка `.help` у неактивной панели не появляется, поэтому
    /// пояснение — своё, по наведению.
    @State private var isHovering = false

    var body: some View {
        if let window = usage.window("five_hour") {
            Text("\(Int((window.utilization * 100).rounded()))%")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(window.utilization >= 0.8 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 11)
                .frame(height: 32)
                .readableSurface(Capsule())
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
                }
                .popover(isPresented: $isHovering, arrowEdge: .top) {
                    UsagePopover(usage: usage)
                }
                .accessibilityLabel(UsageChip.tooltip(usage))
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

private struct UsagePopover: View {
    let usage: SubscriptionUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Лимит подписки Claude")
                .font(.system(size: 13, weight: .semibold))
            Text("Сколько уже потрачено. Когда лимит закончится, Руни не сможет отвечать до сброса.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(usage.windows.filter { $0.kind == "five_hour" || $0.kind == "seven_day" }, id: \.kind) { window in
                UsageWindowRow(window: window)
            }
        }
        .padding(14)
        .frame(width: 260)
    }
}

// MARK: - Общее

extension View {
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
