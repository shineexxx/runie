// Иконка Runie: тёмный квадрат с орбом — тот же шар, что живёт у края экрана.
// Запуск: swift scripts/make-icon.swift App/Runie/Resources/Runie.icns
import AppKit
import Foundation

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Runie.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Runie.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a).cgColor
}

/// Рисует иконку размером side×side.
func render(side: Double) -> Data {
    let pixels = Int(side)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: side, height: side)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext

    // Подложка macOS: скруглённый квадрат с полями, как у системных иконок.
    let inset = side * 0.055
    let box = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let squircle = NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225)
    context.saveGState()
    squircle.addClip()
    let backdrop = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(0.07, 0.12, 0.16), color(0.02, 0.06, 0.09)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(backdrop, start: CGPoint(x: box.minX, y: box.maxY), end: CGPoint(x: box.maxX, y: box.minY), options: [])

    // Орб: тёмное ядро, бирюзовый свет изнутри и мягкий ореол вокруг.
    let center = CGPoint(x: box.midX, y: box.midY)
    let radius = box.width * 0.30
    let halo = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(0.30, 0.90, 0.90, 0.55), color(0.15, 0.60, 0.80, 0.18), color(0.15, 0.60, 0.80, 0)] as CFArray,
        locations: [0, 0.55, 1]
    )!
    context.drawRadialGradient(halo, startCenter: center, startRadius: radius * 0.6,
                               endCenter: center, endRadius: radius * 2.1, options: [])

    let orb = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(0.55, 0.98, 0.96), color(0.10, 0.62, 0.74), color(0.03, 0.16, 0.24)] as CFArray,
        locations: [0, 0.55, 1]
    )!
    context.saveGState()
    context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    context.clip()
    context.drawRadialGradient(
        orb,
        startCenter: CGPoint(x: center.x - radius * 0.35, y: center.y + radius * 0.4), startRadius: 0,
        endCenter: center, endRadius: radius * 1.35,
        options: []
    )
    context.restoreGState()

    // Блик сверху — стекло.
    let gloss = NSBezierPath(ovalIn: NSRect(
        x: center.x - radius * 0.55, y: center.y + radius * 0.18,
        width: radius * 1.1, height: radius * 0.6
    ))
    NSColor(white: 1, alpha: 0.18).setFill()
    gloss.fill()
    context.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(side: Double(size)).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(side: Double(size * 2)).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output]
try process.run()
process.waitUntilExit()
print("иконка: \(output)")
