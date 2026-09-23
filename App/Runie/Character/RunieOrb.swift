import RunieKit
import SwiftUI

/// Настроение орба. Берётся из того, чем занят агент, плюс из того, что происходит
/// с самой кнопкой.
enum RunieMood: String, CaseIterable, Sendable {
    case idle
    case thinking
    case working
    case responding
    /// Кнопку тащат.
    case carried

    init(activity: ChatTimeline.Activity) {
        switch activity {
        case .idle: self = .idle
        case .waiting, .thinking: self = .thinking
        case .working: self = .working
        case .responding: self = .responding
        }
    }

    /// Насколько живо переливается шар: от спокойного дрейфа до быстрого вихря.
    var energy: Double {
        switch self {
        case .idle: 0
        case .thinking: 0.45
        case .responding: 0.6
        case .carried: 0.5
        case .working: 1
        }
    }
}

/// Значок на тёмном ядре, когда свет из орба ушёл в чат.
enum OrbGlyph: Equatable, Sendable {
    case none
    /// Крестик: клик по сжавшемуся ядру закрывает чат.
    case close
}

/// Орб Руни: тёмное стеклянное ядро и живая бирюзовая масса света в нём.
///
/// Свет нарисован кодом: размытые пятна плывут по кривым Лиссажу, складываются и
/// выплёскиваются за волнующийся край капли. Частоты движения постоянные;
/// настроение меняет только амплитуду и яркость, поэтому ничего не прыгает.
///
/// Когда открывается чат, масса света уходит в его сторону — из неё вытекает
/// интерфейс, — а тёмное ядро остаётся на месте, сжимается вдвое и закрывает чат.
struct RunieOrb: View {

    let mood: RunieMood
    var size: CGFloat = 48
    /// 0 — ядро в полный размер, 1 — сжалось вдвое, пока открыт чат.
    var collapse: Double = 0
    /// 0 — свет в шаре, 1 — свет ушёл в чат.
    var release: Double = 0
    /// Куда уходит свет: −1 влево, +1 вправо.
    var releaseDirection: Double = -1
    var glyph: OrbGlyph = .none
    /// Орб не виден — например, спрятан за краем экрана. Тогда свет замирает:
    /// перерисовывать то, чего никто не видит, — пустая трата процессора.
    var isPaused = false

    /// Во сколько раз холст света больше самого шара. Свет выплёскивается за край
    /// и уходит в сторону чата; холст должен вмещать его целиком вместе с хвостом
    /// размытия, иначе свет срежется по прямой. При этом он не больше панели кнопки.
    static let canvasScale: CGFloat = 2.3

    var body: some View {
        OrbFluid(
            energy: mood.energy,
            speaking: mood == .responding ? 1 : 0,
            release: release,
            collapse: collapse,
            releaseDirection: releaseDirection,
            size: size,
            isPaused: isPaused
        )
        .overlay { GlyphView(glyph: glyph, size: size * EdgeButtonController.openScale) }
        .scaleEffect(mood == .carried ? 1.08 : 1)
        .animation(.easeInOut(duration: 0.7), value: mood)
        // Тот же ход пружины, что у поля ввода: свет уходит, пока поле вытекает.
        .animation(.spring(response: 0.46, dampingFraction: 0.8), value: release)
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: collapse)
        .accessibilityHidden(true)
    }
}

/// Бирюзовая палитра орба и всех акцентов Руни. Меняется по времени суток —
/// см. `DayPalette`; вьюхи, которые её читают, перерисовываются сами.
@MainActor
enum OrbPalette {
    static var teal: Color { DayPalette.shared.colors.teal.color }
    static var cyan: Color { DayPalette.shared.colors.cyan.color }
    static var azure: Color { DayPalette.shared.colors.azure.color }
    static var mint: Color { DayPalette.shared.colors.mint.color }
    /// Тёмное ядро под светом. Без него пятна сливаются в ровный диск; когда свет
    /// уходит в чат, остаётся именно оно.
    static var deep: Color { DayPalette.shared.colors.deep.color }
    /// Яркость свечения: ночью орб светит слабее.
    static var glow: Double { DayPalette.shared.colors.glow }
}

// MARK: - Свет

private struct OrbFluid: View, @preconcurrency Animatable {

    var energy: Double
    var speaking: Double
    var release: Double
    var collapse: Double
    let releaseDirection: Double
    let size: CGFloat
    let isPaused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Энергия, «речь» и уход света интерполируются анимацией, а не прыгают.
    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>> {
        get { AnimatablePair(AnimatablePair(energy, speaking), AnimatablePair(release, collapse)) }
        set {
            energy = newValue.first.first
            speaking = newValue.first.second
            release = newValue.second.first
            collapse = newValue.second.second
        }
    }

    private struct Blob {
        /// Цвет берётся из палитры в момент рисования: она меняется в течение дня.
        let color: KeyPath<DayPalette.Colors, DayPalette.RGB>
        let radius: CGFloat
        let frequency: Double
        let phase: Double
    }

    private static let blobs = [
        Blob(color: \.cyan, radius: 0.46, frequency: 1.0, phase: 0),
        Blob(color: \.teal, radius: 0.40, frequency: 1.31, phase: 2.1),
        Blob(color: \.azure, radius: 0.36, frequency: 0.83, phase: 4.2),
        Blob(color: \.mint, radius: 0.28, frequency: 1.57, phase: 1.3)
    ]

    var body: some View {
        // 30 кадров в секунду, а не частота экрана: свет плывёт медленно, и на 120 Гц
        // разницы не видно, а процессор орб в покое грузил на пятую часть.
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || isPaused)) { timeline in
            let time = reduceMotion ? 12 : timeline.date.timeIntervalSinceReferenceDate
            orb(time: time)
        }
        .frame(width: canvasSide, height: canvasSide)
    }

    private var canvasSide: CGFloat { size * RunieOrb.canvasScale }

    private func orb(time: TimeInterval) -> some View {
        let breath = reduceMotion ? 0 : sin(time * 1.5) * 0.018
        let voice = reduceMotion ? 0 : abs(sin(time * 8.5)) * 0.045 * speaking
        let outline = BlobOutline(time: time, energy: energy * (1 - release))
        // Уходя, свет гаснет быстрее, чем летит: к концу пути его уже не видно,
        // и край холста ничего не срезает.
        let remaining = (1 - release) * (1 - release)
        let drift = CGSize(width: releaseDirection * release * Double(size) * 0.4, height: 0)
        // Размер ядра сейчас: сжимается, пока открыт чат.
        let core = size * (1 - (1 - EdgeButtonController.openScale) * CGFloat(collapse))

        return ZStack {
            // Свет, выплёскивающийся за край: те же пятна без обрезки, сильнее
            // размытые и вынесенные дальше от центра.
            Canvas { context, canvasSize in
                context.addFilter(.blur(radius: core * 0.14))
                context.blendMode = .plusLighter
                drawBlobs(
                    in: &context,
                    center: CGPoint(x: canvasSize.width / 2 + drift.width, y: canvasSize.height / 2),
                    side: core,
                    reach: 1.35 + release * 0.8,
                    intensity: (0.45 + 0.35 * energy) * remaining,
                    time: time
                )
            }
            .frame(width: canvasSide, height: canvasSide)

            // Ядро со светом внутри.
            Canvas { context, canvasSize in
                context.fill(Path(ellipseIn: CGRect(origin: .zero, size: canvasSize)), with: .color(OrbPalette.deep))
                context.addFilter(.blur(radius: canvasSize.width * 0.09))
                context.blendMode = .plusLighter
                drawBlobs(
                    in: &context,
                    center: CGPoint(
                        x: canvasSize.width / 2 + drift.width * 0.6,
                        y: canvasSize.height / 2
                    ),
                    side: canvasSize.width,
                    reach: 1,
                    intensity: (0.62 + 0.3 * energy) * remaining,
                    time: time
                )
            }
            .clipShape(outline)
            .frame(width: core, height: core)
            .glassEffect(.regular.tint(OrbPalette.teal.opacity(0.16)).interactive(), in: outline)
        }
        .frame(width: canvasSide, height: canvasSide)
        .scaleEffect(1 + (breath + voice) * (1 - release))
    }

    /// Рисует пятна света. `reach` раздвигает их от центра: 1 — внутри шара,
    /// больше — за его краем.
    private func drawBlobs(
        in context: inout GraphicsContext,
        center: CGPoint,
        side: CGFloat,
        reach: Double,
        intensity: Double,
        time: TimeInterval
    ) {
        let palette = DayPalette.shared.colors
        let intensity = intensity * palette.glow
        guard intensity > 0.005 else { return }
        let slow = (0.20 + 0.06 * energy) * reach
        let fast = 0.12 * energy * reach

        for blob in Self.blobs {
            let f = blob.frequency
            let p = blob.phase
            let dx = slow * sin(time * 0.55 * f + p) + fast * sin(time * 2.6 * f + p * 1.7)
            let dy = slow * cos(time * 0.47 * f + p * 0.8) + fast * cos(time * 2.2 * f + p)
            let radius = side * blob.radius * (1 + 0.12 * energy * sin(time * 1.9 * f + p))
            let rect = CGRect(
                x: center.x + dx * side - radius,
                y: center.y + dy * side - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.fill(Path(ellipseIn: rect), with: .color(palette[keyPath: blob.color].color.opacity(intensity)))
        }
    }
}

// MARK: - Значок

private struct GlyphView: View {
    let glyph: OrbGlyph
    let size: CGFloat

    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: size * 0.36, weight: .bold))
            .foregroundStyle(.white.opacity(0.9))
            .opacity(glyph == .close ? 1 : 0)
            .scaleEffect(glyph == .close ? 1 : 0.5)
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: glyph)
            .allowsHitTesting(false)
    }
}

// MARK: - Форма

/// Край живой капли: окружность, радиус которой волнуется несколькими гармониками
/// с разными скоростями, поэтому форма не повторяется и не выглядит как вращение.
struct BlobOutline: Shape {
    let time: TimeInterval
    let energy: Double

    private static let pointCount = 72

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let base = min(rect.width, rect.height) / 2
        // Даже в покое форма должна читаться как капля, а не как круг.
        let wobble = 0.11 + 0.07 * energy

        // Радиус не выходит за круг: капля «проседает» внутрь, а не выпирает наружу.
        func radius(at angle: Double) -> CGFloat {
            let shape = sin(angle + time * 0.5)
                + 0.9 * sin(angle * 2 + time * 0.9)
                + 0.6 * sin(angle * 3 - time * 1.3)
                + 0.3 * sin(angle * 5 + time * 1.7)
            let normalized = (shape / 2.8 + 1) / 2
            return base * CGFloat(1 - wobble * normalized)
        }

        var path = Path()
        for index in 0...Self.pointCount {
            let angle = Double(index) / Double(Self.pointCount) * 2 * .pi
            let r = radius(at: angle)
            let point = CGPoint(x: center.x + r * CGFloat(cos(angle)), y: center.y + r * CGFloat(sin(angle)))
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }
}
