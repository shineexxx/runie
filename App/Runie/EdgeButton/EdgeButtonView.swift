import RunieKit
import SwiftUI

/// Орб Руни в своей панели. Настроение следует за агентом. Прицепленный к краю,
/// орб наполовину утоплен в кромку экрана, а край выпирает к нему чёрным горбом.
struct EdgeButtonView: View {

    let state: EdgeButtonState
    let session: ChatSession
    let chatLayout: ChatLayout

    var body: some View {
        ZStack {
            if let dock = state.dock {
                OrbTether(edge: dock, extent: tetherExtent)
                    .fill(.black)
                    // Мягкий ореол вокруг горба, как у Eney: горб читается и на тёмных обоях.
                    .shadow(color: .white.opacity(0.09), radius: 14)
                    .animation(.spring(response: 0.22, dampingFraction: 0.85), value: tetherExtent)
                    // Оторвавшийся от края орб горб не тащит: иначе вместе с панелью
                    // на экран выезжает его часть, спрятанная за кромкой.
                    .opacity(state.isAttached ? 1 : 0)

                // Спрятанный орб светится из-за горбика: видно, что Руни рядом.
                EdgeGlow(edge: dock, energy: mood.energy)
                    .opacity(state.isAttached && state.isRetracted ? 1 : 0)
                    .animation(.easeInOut(duration: 0.35), value: state.isRetracted)
            }

            RunieOrb(
                mood: mood,
                collapse: chatLayout.isOpen ? 1 : 0,
                release: release,
                releaseDirection: releaseDirection,
                glyph: chatLayout.isOpen ? .close : .none
            )
            .scaleEffect(state.isPressed && !state.isDragging ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: state.isPressed)
            // Спрятанный шар уезжает за кромку и гаснет, чтобы свет не торчал из-за края.
            .offset(x: retractOffset)
            .opacity(state.isRetracted ? 0 : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.85), value: state.isRetracted)
        }
        .frame(width: EdgeButtonController.panelSize.width, height: EdgeButtonController.panelSize.height)
        .help(chatLayout.isOpen ? "Закрыть чат" : "Руни")
        .accessibilityElement()
        .accessibilityLabel("Руни")
        .accessibilityValue(accessibilityStatus)
        .accessibilityHint(chatLayout.isOpen ? "Закрыть чат" : "Открыть чат")
    }

    /// Горб во весь рост у выглянувшего орба, маленький горбик у спрятанного.
    private var tetherExtent: CGFloat {
        guard state.isAttached else { return 0 }
        return state.isRetracted ? 0.32 : 1
    }

    private var retractOffset: CGFloat {
        guard state.isRetracted else { return 0 }
        return state.dock == .left ? -EdgeButtonController.orbDiameter : EdgeButtonController.orbDiameter
    }

    private var mood: RunieMood {
        #if DEBUG
        // Для работы над внешним видом: `-RunieMood working` в аргументах запуска.
        if let forced = UserDefaults.standard.string(forKey: "RunieMood").flatMap(RunieMood.init(rawValue:)) {
            return forced
        }
        #endif
        return state.isDragging ? .carried : RunieMood(activity: session.timeline.activity)
    }

    /// Открытый чат забирает свет из орба: из него и вытекает интерфейс. Пока агент
    /// работает, свет возвращается в маленькое ядро — видно, что Руни занят.
    private var release: Double {
        chatLayout.isOpen && !session.isBusy ? 1 : 0
    }

    /// Свет уходит туда, где открывается чат.
    private var releaseDirection: Double {
        chatLayout.orbSide == .trailing ? -1 : 1
    }

    private var accessibilityStatus: String {
        switch RunieMood(activity: session.timeline.activity) {
        case .idle, .carried: "свободен"
        case .thinking: "думает"
        case .working: "работает"
        case .responding: "отвечает"
        }
    }
}

/// Чёрный горб, которым кромка экрана держит прицепленный орб: плавно, колоколом
/// выходит из края и обнимает шар. `extent` втягивает его обратно в край.
struct OrbTether: Shape, @preconcurrency Animatable {
    let edge: EdgeButtonState.Edge
    var extent: CGFloat

    var animatableData: CGFloat {
        get { extent }
        set { extent = newValue }
    }

    /// Насколько горб выступает из края и какой он высоты — в долях диаметра орба.
    private static let depth: CGFloat = 0.8
    private static let halfHeight: CGFloat = 1.1

    func path(in rect: CGRect) -> Path {
        let d = EdgeButtonController.orbDiameter
        // Рисуем для правого края и отражаем для левого.
        let cy = rect.midY
        let wall = rect.midX + EdgeButtonController.attachedInset
        // За кромку горб заходит совсем чуть-чуть — только чтобы не было щели.
        let beyond = wall + 2
        let depth = d * Self.depth * extent
        let half = min(d * Self.halfHeight * sqrt(max(extent, 0)), rect.height / 2)
        let apex = wall - depth

        var path = Path()
        path.move(to: CGPoint(x: beyond, y: cy - half))
        path.addLine(to: CGPoint(x: wall, y: cy - half))
        // Колокол: у края касательная вдоль кромки, у вершины — отвесная.
        path.addCurve(
            to: CGPoint(x: apex, y: cy),
            control1: CGPoint(x: wall - depth * 0.35, y: cy - half * 0.55),
            control2: CGPoint(x: apex, y: cy - half * 0.5)
        )
        path.addCurve(
            to: CGPoint(x: wall, y: cy + half),
            control1: CGPoint(x: apex, y: cy + half * 0.5),
            control2: CGPoint(x: wall - depth * 0.35, y: cy + half * 0.55)
        )
        path.addLine(to: CGPoint(x: beyond, y: cy + half))
        path.closeSubpath()

        guard edge == .left else { return path }
        return path.applying(CGAffineTransform(translationX: rect.maxX + rect.minX, y: 0).scaledBy(x: -1, y: 1))
    }
}

/// Лёгкое бирюзовое свечение у горбика спрятанного орба. Медленно дышит, а когда
/// агент работает, светит ярче.
private struct EdgeGlow: View {
    let edge: EdgeButtonState.Edge
    let energy: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let breath = reduceMotion ? 0.5 : (sin(time * 1.3) + 1) / 2
            let strength = (0.22 + 0.12 * breath) * (1 + 0.6 * energy)

            ZStack {
                Ellipse()
                    .fill(OrbPalette.cyan.opacity(strength))
                    .frame(width: 16, height: 40)
                    .blur(radius: 8)
                Ellipse()
                    .fill(OrbPalette.mint.opacity(strength * 0.8))
                    .frame(width: 5, height: 16)
                    .blur(radius: 3)
            }
            .blendMode(.plusLighter)
            // У вершины горбика: он выступает из кромки примерно до центра панели.
            .offset(x: edge == .right ? 2 : -2)
        }
        .allowsHitTesting(false)
    }
}
