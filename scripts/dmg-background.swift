// Фон окна установщика Runie: тёмная бирюза, свет из-за края, как от орба.
// Запуск: swift scripts/dmg-background.swift assets/dmg-background.png
import AppKit
import Foundation

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/dmg-background.png"
let width = 660.0, height = 420.0
let scale = 2

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(width) * scale, pixelsHigh: Int(height) * scale,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
rep.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let context = NSGraphicsContext.current!.cgContext

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a).cgColor
}

// Фон: от почти чёрного к глубокой бирюзе.
let background = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color(0.04, 0.07, 0.10), color(0.03, 0.17, 0.22), color(0.03, 0.10, 0.16)] as CFArray,
    locations: [0, 0.6, 1]
)!
context.drawLinearGradient(background, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])

// Свет из-за левого края — тот самый орб, только за кадром.
let glow = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color(0.35, 0.95, 0.92, 0.30), color(0.20, 0.70, 0.85, 0.10), color(0.2, 0.7, 0.85, 0)] as CFArray,
    locations: [0, 0.45, 1]
)!
context.drawRadialGradient(
    glow,
    startCenter: CGPoint(x: width * 0.12, y: height * 0.72), startRadius: 0,
    endCenter: CGPoint(x: width * 0.12, y: height * 0.72), endRadius: width * 0.6,
    options: []
)

func draw(_ text: String, size: Double, weight: NSFont.Weight, color textColor: NSColor, at point: CGPoint, centeredIn area: Double? = nil) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: textColor,
        .kern: size * 0.01
    ]
    let string = NSAttributedString(string: text, attributes: attributes)
    var origin = point
    if let area {
        origin.x = (area - string.size().width) / 2
    }
    string.draw(at: origin)
}

draw("Runie", size: 34, weight: .semibold, color: .white, at: CGPoint(x: 0, y: height - 92), centeredIn: width)
draw("Перетащите в «Программы» · Drag to Applications",
     size: 13, weight: .regular, color: NSColor(white: 1, alpha: 0.6),
     at: CGPoint(x: 0, y: height - 120), centeredIn: width)

// Стрелка между иконками: от приложения к папке «Программы».
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: width / 2 - 34, y: height - 232))
arrow.line(to: NSPoint(x: width / 2 + 26, y: height - 232))
arrow.lineWidth = 3
arrow.lineCapStyle = .round
NSColor(white: 1, alpha: 0.45).setStroke()
arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: width / 2 + 34, y: height - 232))
head.line(to: NSPoint(x: width / 2 + 20, y: height - 224))
head.line(to: NSPoint(x: width / 2 + 20, y: height - 240))
head.close()
NSColor(white: 1, alpha: 0.45).setFill()
head.fill()

draw("Нужен Claude Code · Requires Claude Code",
     size: 11, weight: .regular, color: NSColor(white: 1, alpha: 0.38),
     at: CGPoint(x: 0, y: 26), centeredIn: width)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("фон установщика: \(output)")
