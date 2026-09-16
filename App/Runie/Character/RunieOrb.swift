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
    /// Стрелка отправки. Тусклая, пока отправлять нечего.
    case send(enabled: Bool)
    case stop
}

/// Орб Руни: тёмное стеклянное ядро и живая бирюзовая масса света в нём.
///
/// Свет нарисован кодом: размытые пятна плывут по кривым Лиссажу, складываются и
/// выплёскиваются за волнующийся край капли. Частоты движения постоянные;
/// настроение меняет только амплитуду и яркость, поэтому ничего не прыгает.
///
/// Когда открывается чат, масса света уходит в его сторону — из неё вытекает
/// интерфейс, — а ядро остаётся на месте и становится кнопкой со стрелкой.
struct RunieOrb: View {

    let mood: RunieMood
    var size: CGFloat = 48
    /// 0 — свет в шаре, 1 — свет ушёл в чат.
    var release: Double = 0
    /// Куда уходит свет: −1 влево, +1 вправо.
    var releaseDirection: Double = -1
    var glyph: OrbGlyph = .none

    /// Во сколько раз холст света больше самого шара. Свет выплёскивается за край
    /// и уходит в сторону чата; холст должен вмещать его целиком вместе с хвостом
    /// размытия, иначе свет срежется по прямой. При этом он не больше панели кнопки.
    static let canvasScale: CGFloat = 2.3

    var body: some View {
        OrbFluid(
            energy: mood.energy,
            speaking: mood == .responding ? 1 : 0,
            release: release,
            releaseDirection: releaseDirection,
            size: size
        )
        .overlay { GlyphView(glyph: glyph, size: size) }
        .scaleEffect(mood == .carried ? 1.08 : 1)
        .animation(.easeInOut(duration: 0.7), value: mood)
        // Тот же ход пружины, что у поля ввода: свет уходит, пока поле вытекает.
        .animation(.spring(response: 0.46, dampingFraction: 0.8), value: release)
        .accessibilityHidden(true)
    }
}

/// Бирюзовая палитра орба.
enum OrbPalette {
    static let teal = Color(red: 0.10, green: 0.78, blue: 0.74)
    static let cyan = Color(red: 0.30, green: 0.90, blue: 0.98)
    static let azure = Color(red: 0.22, green: 0.56, blue: 1.00)
    static let mint = Color(red: 0.55, green: 1.00, blue: 0.84)
    /// Тёмное ядро под светом. Без него пятна сливаются в ровный диск; когда свет
    /// уходит в чат, остаётся именно оно.
    static let deep = Color(red: 0.03, green: 0.42, blue: 0.58)
}

// MARK: - Свет

private struct OrbFluid: View, @preconcurrency Animatable {

    var energy: Double
    var speaking: Double
    var release: Double
    let releaseDirection: Double
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Энергия, «речь» и уход света интерполируются анимацией, а не прыгают.
    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, Double> {
        get { AnimatablePair(AnimatablePair(energy, speaking), release) }
        set {
            energy = newValue.first.first
            speaking = newValue.first.second
            release = newValue.second
        }
    }

    private struct Blob {
        let color: Color
        let radius: CGFloat
        let frequency: Double
        let phase: Double
    }

    private static let blobs = [
        Blob(color: OrbPalette.cyan, radius: 0.46, frequency: 1.0, phase: 0),
        Blob(color: OrbPalette.teal, radius: 0.40, frequency: 1.31, phase: 2.1),
        Blob(color: OrbPalette.azure, radius: 0.36, frequency: 0.83, phase: 4.2),
        Blob(color: OrbPalette.mint, radius: 0.28, frequency: 1.57, phase: 1.3)
    ]

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
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

        return ZStack {
            // Свет, выплёскивающийся за край: те же пятна без обрезки, сильнее
            // размытые и вынесенные дальше от центра.
            Canvas { context, canvasSize in
                context.addFilter(.blur(radius: size * 0.14))
                context.blendMode = .plusLighter
                drawBlobs(
                    in: &context,
                    center: CGPoint(x: canvasSize.width / 2 + drift.width, y: canvasSize.height / 2),
                    side: size,
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
            .frame(width: size, height: size)
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
            context.fill(Path(ellipseIn: rect), with: .color(blob.color.opacity(intensity)))
        }
    }
}

// MARK: - Значок

private struct GlyphView: View {
    let glyph: OrbGlyph
    let size: CGFloat

    var body: some View {
        ZStack {
            Image(systemName: "arrow.up")
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(.white)
                .opacity(sendOpacity)
                .scaleEffect(sendOpacity > 0 ? 1 : 0.6)

            Image(systemName: "stop.fill")
                .font(.system(size: size * 0.3, weight: .bold))
                .foregroundStyle(.white)
                .opacity(glyph == .stop ? 0.95 : 0)
                .scaleEffect(glyph == .stop ? 1 : 0.6)
        }
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: glyph)
        .allowsHitTesting(false)
    }

    private var sendOpacity: Double {
        switch glyph {
        case .send(let enabled): enabled ? 1 : 0.45
        default: 0
        }
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
