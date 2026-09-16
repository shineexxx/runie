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
            .padding(.horizontal, 8)
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
        let dropdown = ModelDropdown.shared
        if isOpen || dropdown.justClosed {
            dropdown.close()
            return
        }
        guard let rect = anchor.screenRect() else { return }
        isOpen = true
        dropdown.show(
            below: rect,
            models: session.availableModels,
            selected: session.selectedModel ?? "default",
            onSelect: select,
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
            return session.selectedModel ?? "Модель"
        }
        return ModelNames.short(model)
    }
}

#if DEBUG
extension Notification.Name {
    /// `-RunieOpenModelMenu` — раскрыть список моделей без мыши, для снимков.
    static let runieDebugOpenModelMenu = Notification.Name("RunieDebugOpenModelMenu")
}
#endif

// MARK: - Выпадающий список

/// Панель со списком моделей поверх всех окон Runie.
@MainActor
final class ModelDropdown {

    static let shared = ModelDropdown()

    private static let width: CGFloat = 300
    private static let rowHeight: CGFloat = 46
    private static let inset: CGFloat = 6
    /// Прозрачное поле под тень, чтобы край окна её не срезал.
    private static let margin: CGFloat = 24
    private static let gap: CGFloat = 6

    private var panel: FloatingPanel?
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
        models: [AgentModel],
        selected: String,
        onSelect: @escaping (AgentModel) -> Void,
        onClose: @escaping () -> Void
    ) {
        close()
        generation += 1
        self.onClose = onClose

        let rows = max(models.count, 1)
        let listHeight = CGFloat(rows) * Self.rowHeight + Self.inset * 2
        let size = NSSize(width: Self.width + Self.margin * 2, height: listHeight + Self.margin * 2)

        // Вниз от надписи; если внизу экрана не помещается — вверх.
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .infinite
        let opensDown = anchor.minY - Self.gap - listHeight >= visible.minY
        let listTop = opensDown ? anchor.minY - Self.gap : anchor.maxY + Self.gap + listHeight
        var x = anchor.midX - Self.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - Self.width - 8)
        let frame = NSRect(
            x: x - Self.margin,
            y: listTop - listHeight - Self.margin,
            width: size.width,
            height: size.height
        )

        state.opensDown = opensDown
        state.isVisible = false
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let content = DropdownView(
            state: state,
            models: models,
            selected: selected,
            onSelect: { [weak self] model in
                onSelect(model)
                self?.close()
            }
        )
        let hosting = FirstMouseHostingView(rootView: AnyView(content))
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            state.isVisible = true
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

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(size: NSSize(width: 10, height: 10), allowsKey: false)
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
    let models: [AgentModel]
    let selected: String
    let onSelect: (AgentModel) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if models.isEmpty {
                Text("Загружаю модели…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 46)
            }
            ForEach(models) { model in
                DropdownRow(model: model, isSelected: model.value == selected) {
                    onSelect(model)
                }
            }
        }
        .padding(6)
        .frame(width: 300)
        .readableSurface(RoundedRectangle(cornerRadius: 22))
        // Выезжает из надписи: растёт от края, ближнего к ней.
        .scaleEffect(x: state.isVisible ? 1 : 0.92, y: state.isVisible ? 1 : 0.4,
                     anchor: state.opensDown ? .top : .bottom)
        .offset(y: state.isVisible ? 0 : (state.opensDown ? -8 : 8))
        .opacity(state.isVisible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: state.opensDown ? .top : .bottom)
        .padding(24)
    }
}

private struct DropdownRow: View {
    let model: AgentModel
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(ModelNames.title(model))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(ModelNames.detail(model))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(OrbPalette.teal)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(.primary.opacity(isHovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
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

private struct WindowAnchorReader: NSViewRepresentable {
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
        "Best for everyday, complex tasks": "для повседневных и сложных задач",
        "Most capable for your hardest and longest-running tasks": "самая способная — для самых трудных и долгих задач",
        "Efficient for routine tasks": "экономная — для обычных задач",
        "Fastest for quick answers": "самая быстрая — для коротких ответов",
    ]

    /// «Opus 5 with 1M context» → «Opus 5».
    private static func baseName(_ model: AgentModel) -> String {
        let head = model.description.components(separatedBy: " · ").first ?? ""
        let name = head.components(separatedBy: " with ").first?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? model.displayName : name
    }

    /// Коротко для кнопки: «Opus 5».
    static func short(_ model: AgentModel) -> String {
        baseName(model)
    }

    /// Строка меню: «По умолчанию» или «Sonnet 5». Коротко, чтобы меню было узким.
    static func title(_ model: AgentModel) -> String {
        model.value == "default" ? "По умолчанию" : baseName(model)
    }

    static func detail(_ model: AgentModel) -> String {
        let parts = model.description.components(separatedBy: " · ")
        guard parts.count > 1 else { return model.description }
        let tail = parts.dropFirst().joined(separator: " · ")
        let translated = phrases[tail] ?? tail
        return translated.prefix(1).uppercased() + translated.dropFirst()
    }
}
