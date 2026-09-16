import AppKit
import Observation
import SwiftUI

/// Цвета Руни, которые плавно меняются в течение суток.
///
/// Утром бирюза теплее и мятная, днём — яркая голубая, вечером уходит в лазурь,
/// ночью становится приглушённо-синей и светит слабее. Цвета перетекают между
/// опорными часами постепенно, без рывков. Красный ошибок и оранжевый лимита не
/// трогаются: у них свой смысл.
@MainActor
@Observable
final class DayPalette {

    static let shared = DayPalette()

    struct RGB: Equatable, Sendable {
        var r, g, b: Double

        var color: Color { Color(red: r, green: g, blue: b) }

        func mixed(with other: RGB, _ t: Double) -> RGB {
            RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
        }
    }

    struct Colors: Equatable, Sendable {
        var teal, cyan, azure, mint, deep: RGB
        /// Насколько ярко светит орб: ночью слабее.
        var glow: Double

        func mixed(with other: Colors, _ t: Double) -> Colors {
            Colors(
                teal: teal.mixed(with: other.teal, t),
                cyan: cyan.mixed(with: other.cyan, t),
                azure: azure.mixed(with: other.azure, t),
                mint: mint.mixed(with: other.mint, t),
                deep: deep.mixed(with: other.deep, t),
                glow: glow + (other.glow - glow) * t
            )
        }

        static let morning = Colors(
            teal: RGB(r: 0.18, g: 0.80, b: 0.66),
            cyan: RGB(r: 0.45, g: 0.95, b: 0.86),
            azure: RGB(r: 0.30, g: 0.68, b: 0.95),
            mint: RGB(r: 0.72, g: 1.00, b: 0.78),
            deep: RGB(r: 0.05, g: 0.44, b: 0.50),
            glow: 0.95
        )
        /// Дневная — исходная палитра Руни.
        static let day = Colors(
            teal: RGB(r: 0.10, g: 0.78, b: 0.74),
            cyan: RGB(r: 0.30, g: 0.90, b: 0.98),
            azure: RGB(r: 0.22, g: 0.56, b: 1.00),
            mint: RGB(r: 0.55, g: 1.00, b: 0.84),
            deep: RGB(r: 0.03, g: 0.42, b: 0.58),
            glow: 1
        )
        static let evening = Colors(
            teal: RGB(r: 0.14, g: 0.62, b: 0.86),
            cyan: RGB(r: 0.36, g: 0.74, b: 1.00),
            azure: RGB(r: 0.38, g: 0.44, b: 1.00),
            mint: RGB(r: 0.56, g: 0.82, b: 1.00),
            deep: RGB(r: 0.09, g: 0.28, b: 0.60),
            glow: 0.92
        )
        static let night = Colors(
            teal: RGB(r: 0.12, g: 0.42, b: 0.68),
            cyan: RGB(r: 0.26, g: 0.52, b: 0.86),
            azure: RGB(r: 0.30, g: 0.36, b: 0.86),
            mint: RGB(r: 0.40, g: 0.62, b: 0.86),
            deep: RGB(r: 0.06, g: 0.19, b: 0.42),
            glow: 0.72
        )
    }

    /// Опорные часы. Между ними цвета перетекают линейно.
    private static let keyframes: [(hour: Double, colors: Colors)] = [
        (0, .night), (5, .night), (8, .morning), (12, .day),
        (17, .day), (20, .evening), (23, .night), (24, .night)
    ]

    static func colors(atHour hour: Double) -> Colors {
        let hour = hour.truncatingRemainder(dividingBy: 24)
        for (index, frame) in keyframes.enumerated().dropFirst() where hour <= frame.hour {
            let previous = keyframes[index - 1]
            let t = (hour - previous.hour) / (frame.hour - previous.hour)
            return previous.colors.mixed(with: frame.colors, t)
        }
        return .night
    }

    private(set) var colors: Colors

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    private init() {
        colors = Self.colors(atHour: Self.currentHour())
        // Раз в минуту: за минуту цвет меняется незаметно, а к вечеру — заметно.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { DayPalette.shared.update() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { DayPalette.shared.update() }
        }
    }

    private func update() {
        let next = Self.colors(atHour: Self.currentHour())
        guard next != colors else { return }
        withAnimation(.easeInOut(duration: 2)) { colors = next }
    }

    private static func currentHour() -> Double {
        #if DEBUG
        // `-RunieHour 21.5` — посмотреть палитру в другое время суток.
        let forced = UserDefaults.standard.double(forKey: "RunieHour")
        if UserDefaults.standard.object(forKey: "RunieHour") != nil { return forced }
        #endif
        let components = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return Double(components.hour ?? 12) + Double(components.minute ?? 0) / 60
    }
}
