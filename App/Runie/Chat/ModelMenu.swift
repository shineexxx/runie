import AppKit
import RunieKit
import SwiftUI


/// Выбор модели прямо в поле ввода. Список — из самого Claude Code: новые модели
/// появляются здесь сами.
///
/// Не системное `Menu`: у него не поменять ни скругление, ни появление. Список —
/// своя стеклянная панель, которая выезжает из надписи вниз (или вверх, если
/// внизу экрана нет места).
struct ModelMenu: View {
    let session: ChatSession
    let settings: AppSettings
    var compact = true

    @State private var anchor = WindowAnchor()
    @State private var isOpen = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 3) {
                Text(currentTitle)
                    .font(.system(size: compact ? 12 : 12.5, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .foregroundStyle(isOpen ? .primary : .secondary)
            .padding(.horizontal, compact ? 5 : 8)
            .frame(height: 26)
            .background(.primary.opacity(isOpen ? 0.08 : 0), in: Capsule())
            .contentShape(Capsule())
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isOpen)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .background(WindowAnchorReader(anchor: anchor))
        .help("Модель Claude")
        .accessibilityLabel("Модель: \(currentTitle)")
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .runieDebugOpenModelMenu)) { _ in
            if compact { toggle() }
        }
        #endif
    }

    private func toggle() {
        let dropdown = GlassDropdown.shared
        if isOpen || dropdown.justClosed {
            dropdown.close()
            return
        }
        guard let rect = anchor.screenRect() else { return }
        isOpen = true
        let selected = session.selectedModel ?? "default"
        dropdown.show(
            below: rect,
            items: session.availableModels.map { model in
                DropdownItem(
                    id: model.value,
                    title: ModelNames.title(model),
                    detail: ModelNames.detail(model),
                    isSelected: model.value == selected,
                    action: { select(model) }
                )
            },
            emptyText: String(localized: "Загружаю модели…"),
            onClose: { isOpen = false }
        )
    }

    private func select(_ model: AgentModel) {
        // «По умолчанию» — значит, как настроено в самом Claude Code.
        let value = model.value == "default" ? nil : model.value
        session.selectModel(value)
        settings.selectedModel = value
    }

    private var currentTitle: String {
        let value = session.selectedModel ?? "default"
        guard let model = session.availableModels.first(where: { $0.value == value }) else {
            return session.selectedModel ?? String(localized: "Модель")
        }
        return ModelNames.short(model)
    }
}

#if DEBUG
extension Notification.Name {
    /// `-RunieOpenModelMenu` — раскрыть список моделей без мыши, для снимков.
    static let runieDebugOpenModelMenu = Notification.Name("RunieDebugOpenModelMenu")
    /// `-RunieOpenAttachMenu` — раскрыть список скрепки.
    static let runieDebugOpenAttachMenu = Notification.Name("RunieDebugOpenAttachMenu")
    static let runieDebugOpenConversations = Notification.Name("RunieDebugOpenConversations")
}
#endif

// MARK: - Выпадающий список

/// Пункт выпадающего списка.
struct DropdownItem: Identifiable {
    let id: String
    let title: String
    var detail: String? = nil
    var symbol: String? = nil
    var isSelected = false
    /// Виден и при поиске — например, «Новый разговор».
    var alwaysVisible = false
    let action: () -> Void
}

/// Закруглённый стеклянный список, выезжающий из кнопки, — поверх всех окон Runie.
/// Один на приложение: открытие нового закрывает прежний.
@MainActor
final class GlassDropdown {

    static let shared = GlassDropdown()

    private static let width: CGFloat = 250
    private static let searchWidth: CGFloat = 290
    private static let searchHeight: CGFloat = 40
    /// Сколько строк видно в списке с поиском — дальше прокрутка.
    private static let visibleRows = 8
    private static let rowHeight: CGFloat = 36
    private static let inset: CGFloat = 5
    /// Прозрачное поле под тень, чтобы край окна её не срезал.
    private static let margin: CGFloat = 24
    private static let gap: CGFloat = 6

    private var panel: FloatingPanel?
    private var plainPanel: FloatingPanel?
    /// Список с поиском принимает ввод с клавиатуры — это отдельное окно.
    private var keyPanel: FloatingPanel?
    private var monitors: [Any] = []
    private var onClose: (() -> Void)?
    private var closedAt = Date.distantPast
    private var generation = 0
    private let state = DropdownState()

    /// Закрылся только что — щелчком по самой надписи. Тот же щелчок не должен
    /// открыть его снова.
    var justClosed: Bool { Date().timeIntervalSince(closedAt) < 0.25 }

    func show(
        below anchor: NSRect,
        items: [DropdownItem],
        emptyText: String = "",
        searchPrompt: String? = nil,
        onClose: @escaping () -> Void
    ) {
        close()
        generation += 1
        self.onClose = onClose

        let searchable = searchPrompt != nil
        let width = searchable ? Self.searchWidth : Self.width
        let rows = searchable ? min(max(items.count, 1), Self.visibleRows) : max(items.count, 1)
        let listHeight = CGFloat(rows) * Self.rowHeight + Self.inset * 2 + (searchable ? Self.searchHeight : 0)
        let size = NSSize(width: width + Self.margin * 2, height: listHeight + Self.margin * 2)

        // Вниз от надписи; если внизу экрана не помещается — вверх.
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .infinite
        let opensDown = anchor.minY - Self.gap - listHeight >= visible.minY
        let listTop = opensDown ? anchor.minY - Self.gap : anchor.maxY + Self.gap + listHeight
        var x = anchor.midX - width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - width - 8)
        let frame = NSRect(
            x: x - Self.margin,
            y: listTop - listHeight - Self.margin,
            width: size.width,
            height: size.height
        )

        state.opensDown = opensDown
        state.isVisible = false
        let panel: FloatingPanel
        if searchable {
            panel = keyPanel ?? makePanel(allowsKey: true)
            keyPanel = panel
        } else {
            panel = plainPanel ?? makePanel(allowsKey: false)
            plainPanel = panel
        }
        self.panel = panel
        let content = DropdownView(
            state: state,
            items: items,
            emptyText: emptyText,
            searchPrompt: searchPrompt,
            width: width,
            listHeight: CGFloat(rows) * Self.rowHeight,
            onSelect: { [weak self] item in
                self?.close()
                item.action()
            }
        )
        // Сначала окно нужного размера и готовая раскладка в скрытом состоянии.
        // Иначе при первом показе SwiftUI раскладывает список в крошечном новом
        // окне и анимирует переезд — список выплывал слева, а не из надписи.
        panel.setFrame(frame, display: false)
        let hosting = FirstMouseHostingView(rootView: AnyView(content))
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
        if searchable { panel.makeKey() }
        let current = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, current == self.generation else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                self.state.isVisible = true
            }
        }
        watchOutsideClicks()
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        generation += 1
        let current = generation
        closedAt = Date()
        stopWatching()
        onClose?()
        onClose = nil
        withAnimation(.easeIn(duration: 0.12)) {
            state.isVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            guard let self, current == self.generation else { return }
            panel.orderOut(nil)
        }
    }

    private func makePanel(allowsKey: Bool) -> FloatingPanel {
        let panel = FloatingPanel(size: NSSize(width: Self.width, height: Self.rowHeight), allowsKey: allowsKey)
        // Над чатом и орбом.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        return panel
    }

    /// Щелчок мимо списка — в Runie или в другом приложении — закрывает его.
    private func watchOutsideClicks() {
        stopWatching()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                if event.window !== self?.panel { self?.close() }
            }
            return event
        }) {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            monitors.append(global)
        }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            // Esc закрывает список, а не весь чат.
            guard event.keyCode == 53 else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.panel?.isVisible == true else { return false }
                self.close()
                return true
            }
            return handled ? nil : event
        }) {
            monitors.append(keys)
        }
    }

    private func stopWatching() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }
}

@MainActor
@Observable
private final class DropdownState {
    var isVisible = false
    var opensDown = true
}

private struct DropdownView: View {
    let state: DropdownState
    let items: [DropdownItem]
    let emptyText: String
    var searchPrompt: String?
    var width: CGFloat = 250
    var listHeight: CGFloat = 0
    let onSelect: (DropdownItem) -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [DropdownItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }
        return items.filter {
            $0.alwaysVisible || $0.title.localizedCaseInsensitiveContains(trimmed)
                || ($0.detail ?? "").localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let searchPrompt {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField(searchPrompt, text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($searchFocused)
                        // Return открывает первый найденный.
                        .onSubmit {
                            if let first = filtered.first(where: { !$0.alwaysVisible }) ?? filtered.first {
                                onSelect(first)
                            }
                        }
                }
                .padding(.horizontal, 10)
                .frame(height: 40)
                .onAppear { searchFocused = true }

                ScrollView {
                    rows
                }
                .scrollIndicators(.never)
                .frame(height: listHeight)
            } else {
                rows
            }
        }
        .padding(5)
        .frame(width: width)
        .readableSurface(RoundedRectangle(cornerRadius: 18))
        // Выезжает из надписи: растёт от края, ближнего к ней.
        .scaleEffect(x: state.isVisible ? 1 : 0.92, y: state.isVisible ? 1 : 0.4,
                     anchor: state.opensDown ? .top : .bottom)
        .offset(y: state.isVisible ? 0 : (state.opensDown ? -8 : 8))
        .opacity(state.isVisible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: state.opensDown ? .top : .bottom)
        .padding(24)
    }

    private var rows: some View {
        VStack(spacing: 0) {
            if items.isEmpty {
                Text(emptyText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            ForEach(filtered) { item in
                DropdownRow(item: item) { onSelect(item) }
            }
            if !items.isEmpty, filtered.allSatisfy(\.alwaysVisible), !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Ничего не нашлось")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
        }
    }
}

private struct DropdownRow: View {
    let item: DropdownItem
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let symbol = item.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OrbPalette.teal)
                        .frame(width: 18)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if let detail = item.detail {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if item.isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(OrbPalette.teal)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(.primary.opacity(isHovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 13))
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// Хостинг, который принимает первый же щелчок по неактивной панели.
private final class FirstMouseHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Положение на экране

/// Где на экране лежит вьюха: SwiftUI сам этого не говорит, а список открывается
/// отдельным окном.
@MainActor
final class WindowAnchor {
    weak var view: NSView?

    func screenRect() -> NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

struct WindowAnchorReader: NSViewRepresentable {
    let anchor: WindowAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

/// Русские подписи к моделям. CLI отдаёт их по-английски; знакомые фразы
/// переводятся, незнакомые — например, у только что вышедшей модели — остаются как есть.
enum ModelNames {

    private static let phrases: [String: String] = [
        "Best for everyday, complex tasks": String(localized: "для повседневных и сложных задач"),
        "Most capable for your hardest and longest-running tasks": String(localized: "для самых трудных и долгих задач"),
        "Efficient for routine tasks": String(localized: "экономная — для обычных задач"),
        "Fastest for quick answers": String(localized: "самая быстрая — для коротких ответов"),
    ]

    /// «Opus 5 with 1M context» → «Opus 5»;
    /// «Use the default model (currently Opus 5 (1M context))» → «Opus 5».
    static func baseName(_ model: AgentModel) -> String {
        var head = model.description.components(separatedBy: " · ").first ?? ""
        if let range = head.range(of: "(currently ") {
            head = String(head[range.upperBound...])
        }
        let name = head
            .components(separatedBy: " with ").first?
            .components(separatedBy: " (").first?
            .trimmingCharacters(in: CharacterSet(charactersIn: " )")) ?? ""
        return name.isEmpty ? model.displayName : name
    }

    /// Коротко для кнопки: «Opus 5».
    static func short(_ model: AgentModel) -> String {
        baseName(model)
    }

    /// Строка меню: «По умолчанию» или «Sonnet 5». Коротко, чтобы меню было узким.
    static func title(_ model: AgentModel) -> String {
        // У «По умолчанию» в скобках — какая модель за ним сейчас стоит.
        model.value == "default" ? String(localized: "По умолчанию (\(baseName(model)))") : baseName(model)
    }

    static func detail(_ model: AgentModel) -> String {
        if model.value == "default" { return String(localized: "Как настроено в Claude Code") }
        let parts = model.description.components(separatedBy: " · ")
        guard parts.count > 1 else { return model.description }
        let tail = parts.dropFirst().joined(separator: " · ")
        let translated = phrases[tail] ?? tail
        return translated.prefix(1).uppercased() + translated.dropFirst()
    }
}
