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
    let setup: SetupModel
    let layout: ChatLayout
    let tracker: FrontmostAppTracker
    let suggestions: SuggestionsModel
    let briefing: MorningBriefing
    let onSend: (String) -> Void
    let onClose: () -> Void
    /// Открыть окно Runie на этом разговоре.
    let onOpenWindow: () -> Void
    let onPickFiles: () -> Void
    let onCapture: () -> Void
    let onPaste: () -> Void
    let onRetry: () -> Void
    /// Вернуть клавиатуру в поле ввода — после списка с поиском.
    let onRefocus: () -> Void

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
            // Почти невидимая заливка на всю панель.
            //
            // Окно чата прозрачное, а macOS отдаёт нажатия и прокрутку сквозь
            // полностью прозрачные пиксели тому окну, что под ними: событие не
            // доходило до Руни вовсе, и человек, ведя мышью по ответу, прокручивал
            // чужое приложение. Заливка глазу незаметна (меньше одного процента),
            // но окно с ней становится сплошным для системы.
            Color.black.opacity(0.008)

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
                    Group {
                        if setup.isReady {
                            CompactFeed(
                                session: session,
                                greeting: suggestions.greeting,
                                openGeneration: layout.openGeneration,
                                onRetry: onRetry
                            )
                        } else {
                            // Пока Руни не готов, вместо ленты — знакомство по шагам.
                            SetupFeed(setup: setup)
                        }
                    }
                        .modifier(EmergeFromLight(progress: emergence, window: 0.34...0.82, anchor: orbCornerAnchor))

                    // Один раз предлагаем скачать модель смыслового поиска по памяти.
                    if setup.offersMemory {
                        MemoryOfferCard(setup: setup)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: orbCornerAnchor)))
                    }

                    // Сервису нужен ключ — защищённое поле прямо над полем ввода.
                    // Руни спрашивает — карточка с вариантами прямо над полем.
                    if let question = QuestionBroker.shared.pending {
                        QuestionCard(request: question, broker: QuestionBroker.shared)
                            .id(question.id)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: orbCornerAnchor)))
                    }

                    if let secret = SecretBroker.shared.pending {
                        SecretCard(request: secret, broker: SecretBroker.shared)
                            .id(secret.id)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: orbCornerAnchor)))
                    }

                    // Агент стоит и ждёт ответа — вопрос прямо над полем ввода.
                    if let request = session.pendingPermission {
                        PermissionCard(request: request, session: session)
                            .id(request.requestID)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: orbCornerAnchor)))
                    }

                    // Набирается «/…» — свои команды прямо над полем.
                    let commandMatches = QuickCommand.matching(layout.draft, in: QuickCommandsModel.shared.commands)
                    if !commandMatches.isEmpty {
                        CommandSuggestions(matches: commandMatches) { layout.draft = "/\($0.command) " }
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    if !layout.attachments.isEmpty {
                        AttachmentStrip(attachments: Binding(
                            get: { layout.attachments },
                            set: { layout.attachments = $0 }
                        ))
                        .frame(height: 68)
                        .frame(maxWidth: 420, alignment: frameAlignment)
                        .readableSurface(RoundedRectangle(cornerRadius: 20))
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    InputRow(
                        session: session,
                        settings: settings,
                        onPickFiles: onPickFiles,
                        onCapture: onCapture,
                        onPaste: onPaste,
                        layout: layout,
                        onSubmitDraft: submitDraft,
                        onStop: { session.stop() },
                        onOpenWindow: onOpenWindow,
                        onRefocus: onRefocus
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
                        suggestions: chipSuggestions,
                        alignment: frameAlignment,
                        onSend: { text in
                            if text == MorningBriefing.prompt { briefing.markDone() }
                            onSend(text)
                        }
                    )
                    .opacity(setup.isReady ? 1 : 0)
                    .allowsHitTesting(setup.isReady)
                    .frame(height: ChatPanelController.chipsHeight)
                    .modifier(EmergeFromLight(progress: emergence, window: 0.26...0.72, anchor: orbCornerAnchor))
                }
                // Поля шире тени блоков, иначе край окна её обрезает.
                .padding(.horizontal, ChatPanelController.shadowMargin)
                .padding(.bottom, ChatPanelController.bottomInset)
                .frame(width: ChatPanelController.size.width)
                // Под блоками — подложка, которая забирает прокрутку и клики себе.
                // Без неё колесо мыши над ответом Руни крутило окно позади.
                .background(ChatEventCatcher())
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    /// Утром, пока день не разобран, первая подсказка — «Разобрать день».
    private var chipSuggestions: [Suggestion] {
        guard briefing.isDue else { return suggestions.current }
        return [MorningBriefing.suggestion] + suggestions.current.filter { $0 != MorningBriefing.suggestion }.prefix(1)
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
        // Return на недописанной «/отч» подставляет команду, а не отправляет обрывок.
        let matches = QuickCommand.matching(layout.draft, in: QuickCommandsModel.shared.commands)
        if let first = matches.first, QuickCommand.normalize(layout.draft) != QuickCommand.normalize(first.command) {
            layout.draft = "/\(first.command) "
            return
        }
        guard layout.hasDraft, !session.isBusy, setup.isReady else { return }
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

    private static var colors: [Color] { [OrbPalette.cyan, OrbPalette.teal, OrbPalette.azure, OrbPalette.mint] }

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
// MARK: - Компактная лента

private struct CompactFeed: View {
    let session: ChatSession
    let greeting: String
    /// Меняется при каждом открытии чата — развёрнутая лента снова сворачивается.
    let openGeneration: Int
    let onRetry: () -> Void

    /// Сколько места над полем ввода.
    @State private var available: CGFloat = 0
    /// Высота текущего хода — в свёрнутом виде видно только его.
    @State private var currentHeight: CGFloat = 0
    /// Человек прокрутил вверх: лента раскрывается на всю высоту с прошлыми репликами.
    @State private var expanded = false

    /// Запас вокруг облачков под их тень (радиус 16, сдвиг 6).
    private static let shadowRoom: CGFloat = 28

    var body: some View {
        let turns = ChatTurn.split(session.timeline.items)
        let past = turns.dropLast()

        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { available = $0 }
            .overlay(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(past) { turn in
                            PastTurnView(turn: turn)
                        }
                        CurrentTurnView(session: session, turn: turns.last, greeting: greeting, onRetry: onRetry)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { currentHeight = $0 }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Поле под тень облачков: прокрутка обрезает всё, что за её краем.
                    .padding(Self.shadowRoom)
                }
                .scrollIndicators(.never)
                .scrollPosition($position)
                .defaultScrollAnchor(.bottom)
                // Прокручивает сам человек — раскрываемся и больше не тянем к последней строке.
                .onScrollPhaseChange { _, phase in
                    guard phase == .interacting, !expanded, past.count > 0 || currentHeight > available else { return }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { expanded = true }
                }
                // Пока ответ печатается, держимся у последней строки.
                .onChange(of: currentHeight) { followBottom() }
                .onChange(of: feedHeight) { followBottom() }
                .frame(height: feedHeight + Self.shadowRoom * 2)
                // Раскрытая лента уходит вверх в прозрачность, а не обрывается краем.
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: expanded || currentHeight > available ? Self.shadowRoom + 40 : 0)
                        Color.black
                    }
                }
                // Поле под тень выходит за блоки, а облачка остаются на своих местах.
                .padding(-Self.shadowRoom)
            }
            .onChange(of: openGeneration) { collapse() }
            .onChange(of: turns.count) { collapse() }
    }

    @State private var position = ScrollPosition(edge: .bottom)

    private func followBottom() {
        guard !expanded else { return }
        position.scrollTo(edge: .bottom)
    }

    private func collapse() {
        expanded = false
        position.scrollTo(edge: .bottom)
    }

    private var feedHeight: CGFloat {
        let limit = max(available, 1)
        return expanded ? limit : min(max(currentHeight, 1), limit)
    }
}

/// Прошлый ход: только облачка — моё сообщение и итог Руни.
private struct PastTurnView: View {
    let turn: ChatTurn

    var body: some View {
        if let user = turn.user {
            UserMessageBubble(text: user.text, attachments: user.attachments ?? [])
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        if let failure = turn.failure {
            Bubble(tail: .leading) { Text(failure.text).foregroundStyle(.red) }
        } else if let reply = turn.reply {
            ReplyBubble(text: reply)
        }
    }
}

/// Текущий ход: моё сообщение, «руки», ответ или приветствие.
private struct CurrentTurnView: View {
    let session: ChatSession
    let turn: ChatTurn?
    let greeting: String
    let onRetry: () -> Void

    var body: some View {
        let timeline = session.timeline
        // Пока висит вопрос о разрешении, всё про текущее действие уже в карточке.
        let asking = session.pendingPermission != nil

        // Как в мессенджере: моё сообщение справа, Руни отвечает слева.
        VStack(alignment: .leading, spacing: 8) {
            if let user = turn?.user {
                UserMessageBubble(text: user.text, attachments: user.attachments ?? [])
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if let action = turn?.lastAction, showsAction(action), !asking {
                ActionCapsule(action: action)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if let failure = turn?.failure, !timeline.isBusy {
                Bubble(tail: .leading) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(failure.text).foregroundStyle(.red)
                        if session.lastUserMessage != nil {
                            Button(action: onRetry) {
                                Label("Повторить", systemImage: "arrow.clockwise")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(PermissionButtonStyle(kind: .secondary))
                        }
                    }
                }
            } else if let reply = turn?.reply {
                ReplyBubble(text: reply, onRetry: timeline.isBusy ? nil : onRetry)
            } else if timeline.isBusy, !asking {
                Bubble(tail: .leading) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(ActivityLabel.text(timeline.activity))
                            .foregroundStyle(.secondary)
                    }
                }
            } else if timeline.items.isEmpty {
                Bubble(tail: .leading) {
                    Text(greeting)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.35), value: greeting)
                }
            } else if let notice = turn?.lastNotice {
                Bubble(tail: .leading) { Text(notice.text).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: turn?.lastAction?.id)
    }

    /// «Руки» видны, пока агент работает, или если последнее действие не удалось.
    private func showsAction(_ action: ActionItem) -> Bool {
        session.isBusy || action.status == .denied || action.status == .failed
    }
}

/// Ответ Руни. При наведении над углом облачка — «Скопировать» и «Повторить».
private struct ReplyBubble: View {
    let text: String
    var onRetry: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        Bubble(tail: .leading) {
            RichMessageText(text: text, imageWidth: 300)
                // Полужирный пузыря хорош для коротких реплик, а в абзаце тяжелит.
                .fontWeight(.regular)
                .lineSpacing(2)
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 0) {
                CopyButton(text: text, label: String(localized: "Скопировать ответ"), size: 12)
                if let onRetry {
                    Button(action: onRetry) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Спросить ещё раз")
                    .accessibilityLabel("Спросить ещё раз")
                }
            }
            .padding(.horizontal, 3)
            .readableSurface(Capsule(), interactive: true)
            .offset(x: -6, y: -12)
            .opacity(hovering ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .onHover { hovering = $0 }
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
            // Ширина — не больше 420 и не шире текста, высота — ровно под текст при этой
            // ширине. «Идеальная» ширина здесь не годится: её меряют по самой длинной
            // строке без переносов, а рисуют уже, и длинный ответ вылезал из облачка.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 420, alignment: .leading)
            .readableSurface(MessageBubbleShape(tail: tail))
            // Хвостик выходит за рамку пузыря — место под него.
            .padding(tail == .trailing ? .trailing : .leading, MessageBubbleShape.tailReach)
    }
}

/// Моё сообщение: бирюзовое облачко справа.
struct UserMessageBubble: View {
    let text: String
    var attachments: [Attachment] = []
    var maxWidth: CGFloat = 300

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(attachments.prefix(4)) { attachment in
                        AttachmentThumbnail(attachment: attachment, size: 44)
                    }
                }
            }
            bubble
        }
    }

    private var bubble: some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
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
                // Длинное (код JavaScript) — целиком, с прокруткой: разрешают именно его.
                let text = Text(detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ViewThatFits(in: .vertical) {
                    text.fixedSize(horizontal: false, vertical: true)
                    ScrollView { text }
                }
                .frame(maxHeight: 180)
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
        .frame(width: 420, alignment: .leading)
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
        case "Bash": String(localized: "Больше не спрашивать об этой команде до конца разговора")
        case "WebFetch": String(localized: "Больше не спрашивать об этом сайте до конца разговора")
        default: String(localized: "Больше не спрашивать о таком действии до конца разговора")
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
    let onPickFiles: () -> Void
    let onCapture: () -> Void
    let onPaste: () -> Void
    @Bindable var layout: ChatLayout
    let onSubmitDraft: () -> Void
    let onStop: () -> Void
    let onOpenWindow: () -> Void
    let onRefocus: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        // Плотно: две круглые кнопки и поле делят 480 точек, а подсказке в поле
        // нужна одна строка.
        HStack(spacing: 6) {
            // Кнопки с дальней от орба стороны: разговоры, затем «развернуть».
            if layout.orbSide == .trailing {
                ConversationsButton(session: session, onDone: onRefocus)
                expandButton
            }
            inputPill
            if layout.orbSide == .leading {
                expandButton
                ConversationsButton(session: session, onDone: onRefocus)
            }
        }
        .onAppear { isFocused = true }
        .onChange(of: layout.focusGeneration) { isFocused = true }
        // Файлы можно бросить прямо на поле.
        .acceptsDroppedFiles { files in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { layout.attachments += files }
        }
    }

    /// Кнопка отправки — у ближнего к орбу конца поля, откуда пришёл свет.
    private var inputPill: some View {
        // Плотно: скрепка, снимок, модель и отправка делят поле с текстом, и тексту
        // должно хватать ширины на подсказку в одну строку — иначе она переносится,
        // и многострочное поле подпрыгивает над центром.
        HStack(spacing: 4) {
            if layout.orbSide == .leading { sendButton }
            if layout.orbSide == .trailing { AttachmentButtons(onPickFiles: onPickFiles, onCapture: onCapture, onPaste: onPaste) }

            TextField(placeholder, text: $layout.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                // Пять строк: с переносами по Shift+Enter в трёх уже тесно.
                .lineLimit(1...5)
                .focused($isFocused)
                .onSubmit(onSubmitDraft)
                // Shift+Enter — перенос строки, обычный Enter отправляет.
                // Перенос вставляем в место курсора, а не в конец: человек мог
                // вернуться в середину написанного.
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                        editor.insertText("\n", replacementRange: editor.selectedRange())
                    } else {
                        layout.draft += "\n"
                    }
                    return .handled
                }
                // Tab на «/…» подставляет первую подходящую команду.
                .onKeyPress(.tab) {
                    guard let first = QuickCommand.matching(layout.draft, in: QuickCommandsModel.shared.commands).first
                    else { return .ignored }
                    layout.draft = "/\(first.command) "
                    return .handled
                }
                // ↑ в пустом поле — последнее сообщение, чтобы поправить и отправить заново.
                .onKeyPress(.upArrow) {
                    guard layout.draft.isEmpty, layout.attachments.isEmpty, !session.isBusy,
                          let last = session.lastUserMessage else { return .ignored }
                    layout.draft = last.text
                    layout.attachments = last.attachments
                    return .handled
                }
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            ModelMenu(session: session, settings: settings)
            if layout.orbSide == .leading { AttachmentButtons(onPickFiles: onPickFiles, onCapture: onCapture, onPaste: onPaste) }
            if layout.orbSide == .trailing { sendButton }
        }
        .padding(.leading, layout.orbSide == .trailing ? 8 : 7)
        .padding(.trailing, layout.orbSide == .trailing ? 7 : 8)
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
                .font(.system(size: busy ? 12 : 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
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
        session.isBusy ? String(localized: "Работаю…") : String(localized: "Спросите Руни…")
    }

    private var expandButton: some View {
        Button(action: onOpenWindow) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 40, height: 40)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .readableSurface(Circle(), interactive: true)
        .help("Открыть разговор в окне Runie")
        .accessibilityLabel("Открыть разговор в окне Runie")
    }
}

// MARK: - Разговоры

/// Круглая кнопка с часами: список прошлых разговоров с поиском и «Новый разговор».
/// Выбранный разговор открывается прямо здесь и продолжается с того же места.
private struct ConversationsButton: View {
    let session: ChatSession
    let onDone: () -> Void

    @State private var anchor = WindowAnchor()
    @State private var isOpen = false

    var body: some View {
        Button(action: toggle) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isOpen ? AnyShapeStyle(OrbPalette.teal) : AnyShapeStyle(.primary))
                .frame(width: 40, height: 40)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .readableSurface(Circle(), interactive: true)
        .background(WindowAnchorReader(anchor: anchor))
        .opacity(session.isBusy ? 0.45 : 1)
        .disabled(session.isBusy)
        .help(session.isBusy ? "Руни занят — дождитесь ответа" : "Другие разговоры")
        .accessibilityLabel("Другие разговоры")
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .runieDebugOpenConversations)) { _ in toggle() }
        #endif
    }

    private func toggle() {
        let dropdown = GlassDropdown.shared
        if isOpen || dropdown.justClosed {
            dropdown.close()
            return
        }
        guard let rect = anchor.screenRect(), !session.isBusy else { return }
        isOpen = true
        let current = session.conversationID
        let hasItems = !session.timeline.items.isEmpty
        var items: [DropdownItem] = [
            DropdownItem(
                id: "new", title: "Новый разговор", detail: nil, symbol: "square.and.pencil",
                alwaysVisible: true,
                action: { if hasItems { session.startOver() } }
            )
        ]
        let records = (session.store?.list() ?? []).prefix(50)
        items += records.map { record in
            DropdownItem(
                id: record.id.uuidString,
                title: record.title,
                detail: Self.when(record.updatedAt),
                isSelected: record.id == current,
                action: { if record.id != session.conversationID { session.open(record) } }
            )
        }
        dropdown.show(
            below: rect,
            items: items,
            searchPrompt: String(localized: "Найти разговор"),
            onClose: {
                isOpen = false
                onDone()
            }
        )
    }

    /// «сегодня, 14:20», «вчера, 09:05», «12 сентября».
    private static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(.runie))
        if calendar.isDateInToday(date) { return String(localized: "сегодня, \(time)") }
        if calendar.isDateInYesterday(date) { return String(localized: "вчера, \(time)") }
        return date.formatted(.dateTime.day().month(.wide).locale(.runie))
    }
}

// MARK: - Контекст

/// Где человек сейчас. Клик выключает передачу контекста агенту.
// MARK: - Подсказки

private struct ChipsRow: View {
    let session: ChatSession
    let suggestions: [Suggestion]
    let alignment: Alignment
    let onSend: (String) -> Void

    var body: some View {
        Group {
            if session.timeline.items.isEmpty {
                // Подсказки от ИИ бывают длинными. Не влезают две — показываем одну:
                // иначе ряд распирает столбец блоков, и поле ввода съезжает на орб.
                // ViewThatFits — на весь ряд: внутри HStack он получает неверную ширину.
                ViewThatFits(in: .horizontal) {
                    row { chips(suggestions) }
                    row { chips(Array(suggestions.prefix(1))) }
                }
            } else {
                row {
                    if let usage = session.timeline.usage {
                        UsageChip(usage: usage)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: suggestions)
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            startOverButton
            content()
        }
        .fixedSize()
    }

    private var startOverButton: some View {
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
    }

    private func chips(_ items: [Suggestion]) -> some View {
        HStack(spacing: 8) {
            ForEach(items) { suggestion in
                // На кнопке — короткая надпись, агенту уходит полная просьба.
                Chip(title: suggestion.label) { onSend(suggestion.prompt) }
                    .help(suggestion.prompt)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
    }
}

private struct Chip: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 11)
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
            case "five_hour": String(localized: "за 5 часов")
            case "seven_day": String(localized: "за 7 дней")
            default: window.kind
            }
            return "\(name): \(Int((window.utilization * 100).rounded()))%"
        }
        return String(localized: "Использовано подписки — ") + parts.joined(separator: ", ")
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

/// Прозрачная подложка чата, которая забирает себе прокрутку и нажатия.
///
/// Панель чата безрамочная, прозрачная и не активирует приложение. Там, где
/// SwiftUI не подставил под курсор ничего интерактивного — в промежутке между
/// облачками или над коротким ответом, который нечего прокручивать, — AppKit не
/// находил окна и отдавал событие следующему. Человек вёл мышь по ответу Руни,
/// а прокручивалось окно позади.
///
/// Настоящий NSView решает это раз и навсегда: событие в пределах чата
/// заканчивается здесь. Кнопки, поле ввода и сама лента лежат выше и получают
/// своё первыми — подложке достаётся только то, что иначе утекло бы наружу.
private struct ChatEventCatcher: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView { CatcherView() }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class CatcherView: NSView {
        override func scrollWheel(with event: NSEvent) {}
        override func mouseDown(with event: NSEvent) {}
        override func rightMouseDown(with event: NSEvent) {}
        override func otherMouseDown(with event: NSEvent) {}
        override func magnify(with event: NSEvent) {}
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
        case .waiting: String(localized: "Отправляю…")
        case .thinking: String(localized: "Думает…")
        case .working(let detail): detail ?? String(localized: "Работает…")
        case .responding: String(localized: "Отвечает…")
        }
    }
}

enum MarkdownText {
    /// Жирный, курсив, код и ссылки в строке. Блоки — заголовки, списки, код —
    /// разбирает `MarkdownView`.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
