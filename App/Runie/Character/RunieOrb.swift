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

/// Орб Руни: стеклянный шар, внутри которого переливается бирюзовый свет.
///
/// Нарисован кодом: несколько размытых цветных пятен плывут по кривым Лиссажу
/// и складываются светом. Частоты движения постоянные, настроение меняет только
/// амплитуду и яркость — поэтому при смене настроения пятна не прыгают, а
/// «энергия» перетекает плавно.
struct RunieOrb: View {

    let mood: RunieMood
    var size: CGFloat = 48

    var body: some View {
        OrbFluid(
            energy: mood.energy,
            speaking: mood == .responding ? 1 : 0,
            size: size
        )
        .scaleEffect(mood == .carried ? 1.08 : 1)
        .animation(.easeInOut(duration: 0.7), value: mood)
        .accessibilityHidden(true)
    }
}

/// Бирюзовая палитра орба.
enum OrbPalette {
    static let teal = Color(red: 0.10, green: 0.78, blue: 0.74)
    static let cyan = Color(red: 0.30, green: 0.90, blue: 0.98)
    static let azure = Color(red: 0.22, green: 0.56, blue: 1.00)
    static let mint = Color(red: 0.55, green: 1.00, blue: 0.84)
    /// Глубина под светом. Без тёмного основания светлые пятна сливаются в ровный диск.
    static let deep = Color(red: 0.01, green: 0.22, blue: 0.30)
}

private struct OrbFluid: View, @preconcurrency Animatable {

    var energy: Double
    var speaking: Double
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Энергия и «речь» интерполируются анимацией, а не прыгают.
    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(energy, speaking) }
        set {
            energy = newValue.first
            speaking = newValue.second
        }
    }

    private struct Blob {
        let color: Color
        let radius: CGFloat
        let frequency: Double
        let phase: Double
    }

    private static let blobs = [
        Blob(color: OrbPalette.teal, radius: 0.34, frequency: 1.0, phase: 0),
        Blob(color: OrbPalette.cyan, radius: 0.27, frequency: 1.31, phase: 2.1),
        Blob(color: OrbPalette.azure, radius: 0.30, frequency: 0.83, phase: 4.2),
        Blob(color: OrbPalette.mint, radius: 0.20, frequency: 1.57, phase: 1.3)
    ]

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 12 : timeline.date.timeIntervalSinceReferenceDate
            orb(time: time)
        }
        .frame(width: size, height: size)
    }

    private func orb(time: TimeInterval) -> some View {
        let breath = reduceMotion ? 0 : sin(time * 1.5) * 0.018
        let voice = reduceMotion ? 0 : abs(sin(time * 8.5)) * 0.045 * speaking
        let glow = 0.14 + 0.36 * energy

        return Canvas { context, canvasSize in
            let side = canvasSize.width
            context.fill(Path(ellipseIn: CGRect(origin: .zero, size: canvasSize)), with: .color(OrbPalette.deep))

            context.addFilter(.blur(radius: side * 0.09))
            context.blendMode = .plusLighter

            let slow = 0.20 + 0.06 * energy
            let fast = 0.12 * energy
            let intensity = 0.42 + 0.4 * energy

            for blob in Self.blobs {
                let f = blob.frequency
                let p = blob.phase
                let x = 0.5 + slow * sin(time * 0.55 * f + p) + fast * sin(time * 2.6 * f + p * 1.7)
                let y = 0.5 + slow * cos(time * 0.47 * f + p * 0.8) + fast * cos(time * 2.2 * f + p)
                let radius = side * blob.radius * (1 + 0.12 * energy * sin(time * 1.9 * f + p))
                let rect = CGRect(
                    x: x * side - radius,
                    y: y * side - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                context.fill(Path(ellipseIn: rect), with: .color(blob.color.opacity(intensity)))
            }
        }
        .clipShape(Circle())
        .frame(width: size, height: size)
        .glassEffect(.regular.tint(OrbPalette.teal.opacity(0.16)).interactive(), in: .circle)
        .shadow(color: OrbPalette.cyan.opacity(glow), radius: size * 0.16)
        .scaleEffect(1 + breath + voice)
    }
}
