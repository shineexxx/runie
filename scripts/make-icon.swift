// Иконка Runie: тот же орб, что живёт у края экрана — тёмно-бирюзовое ядро и
// живая масса света в нём. Цвета взяты из дневной палитры DayPalette.
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

// Дневная палитра орба (DayPalette.Colors.day).
let teal = (0.10, 0.78, 0.74)
let cyan = (0.30, 0.90, 0.98)
let azure = (0.22, 0.56, 1.00)
let mint = (0.55, 1.00, 0.84)
let deep = (0.03, 0.42, 0.58)

/// Пятно света внутри ядра: цвет, доля радиуса, смещение от центра.
let blobs: [(rgb: (Double, Double, Double), radius: Double, dx: Double, dy: Double, alpha: Double)] = [
    (cyan, 0.60, -0.22, 0.26, 0.52),
    (azure, 0.66, 0.10, -0.30, 0.50),
    (teal, 0.46, 0.34, 0.10, 0.28),
    (mint, 0.34, -0.30, -0.10, 0.20)
]

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
    // Тёмная, но бирюзовая — того же семейства, что и свет в орбе.
    let inset = side * 0.055
    let box = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let squircle = NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225)
    context.saveGState()
    squircle.addClip()
    let backdrop = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(0.05, 0.24, 0.32), color(0.02, 0.10, 0.16)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(backdrop, start: CGPoint(x: box.minX, y: box.maxY), end: CGPoint(x: box.maxX, y: box.minY), options: [])

    let center = CGPoint(x: box.midX, y: box.midY)
    let radius = box.width * 0.30

    // Свет, выплёскивающийся за край ядра.
    let halo = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            color(cyan.0, cyan.1, cyan.2, 0.32),
            color(azure.0, azure.1, azure.2, 0.14),
            color(azure.0, azure.1, azure.2, 0)
        ] as CFArray,
        locations: [0, 0.5, 1]
    )!
    context.saveGState()
    context.setBlendMode(.plusLighter)
    context.drawRadialGradient(halo, startCenter: center, startRadius: radius * 0.75,
                               endCenter: center, endRadius: radius * 2.2, options: [])
    context.restoreGState()

    // Ядро: тёмная бирюза, поверх неё складываются пятна света.
    let orb = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    context.saveGState()
    context.addEllipse(in: orb)
    context.clip()
    context.setFillColor(color(deep.0, deep.1, deep.2))
    context.fill(orb)
    // Общая бирюза по всему ядру: без неё низ шара уходит в темноту.
    context.setFillColor(color(azure.0, azure.1, azure.2, 0.34))
    context.fill(orb)

    context.setBlendMode(.plusLighter)
    for blob in blobs {
        let r = radius * blob.radius * 2.0
        let spot = CGPoint(x: center.x + radius * blob.dx, y: center.y + radius * blob.dy)
        let light = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                color(blob.rgb.0, blob.rgb.1, blob.rgb.2, blob.alpha),
                color(blob.rgb.0, blob.rgb.1, blob.rgb.2, blob.alpha * 0.45),
                color(blob.rgb.0, blob.rgb.1, blob.rgb.2, 0)
            ] as CFArray,
            locations: [0, 0.45, 1]
        )!
        context.drawRadialGradient(light, startCenter: spot, startRadius: 0,
                                   endCenter: spot, endRadius: r, options: [])
    }
    context.restoreGState()

    // Стекло: блик сверху и светлый ободок по краю.
    context.saveGState()
    context.addEllipse(in: orb)
    context.clip()
    let gloss = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(1, 1, 1, 0.26), color(1, 1, 1, 0)] as CFArray,
        locations: [0, 1]
    )!
    let highlight = CGPoint(x: center.x - radius * 0.28, y: center.y + radius * 0.46)
    context.drawRadialGradient(gloss, startCenter: highlight, startRadius: 0,
                               endCenter: highlight, endRadius: radius * 0.85, options: [])
    context.restoreGState()

    context.setStrokeColor(color(cyan.0, cyan.1, cyan.2, 0.35))
    context.setLineWidth(max(side * 0.004, 0.5))
    context.strokeEllipse(in: orb.insetBy(dx: side * 0.002, dy: side * 0.002))

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
