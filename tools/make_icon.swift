// Genera AppIcon.icns: swift tools/make_icon.swift
import AppKit

let size = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let context = NSGraphicsContext.current!.cgContext

// Fondo: margen estándar de los iconos de macOS
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
tilePath.addClip()
NSGradient(colors: [
    NSColor(red: 0.04, green: 0.73, blue: 0.70, alpha: 1),
    NSColor(red: 0.07, green: 0.31, blue: 0.62, alpha: 1),
    NSColor(red: 0.05, green: 0.09, blue: 0.28, alpha: 1),
])!.draw(in: tile, angle: -90)

// La isla: un notch que cuelga del borde superior
let islandWidth: CGFloat = 560, islandHeight: CGFloat = 250, radius: CGFloat = 92
let left = (CGFloat(size) - islandWidth) / 2, right = left + islandWidth
let top = tile.maxY, bottom = top - islandHeight
let island = CGMutablePath()
island.move(to: CGPoint(x: left, y: top))
island.addLine(to: CGPoint(x: left, y: bottom + radius))
island.addQuadCurve(to: CGPoint(x: left + radius, y: bottom), control: CGPoint(x: left, y: bottom))
island.addLine(to: CGPoint(x: right - radius, y: bottom))
island.addQuadCurve(to: CGPoint(x: right, y: bottom + radius), control: CGPoint(x: right, y: bottom))
island.addLine(to: CGPoint(x: right, y: top))
island.closeSubpath()
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -14), blur: 60, color: NSColor.black.withAlphaComponent(0.5).cgColor)
context.addPath(island)
context.setFillColor(NSColor.black.cgColor)
context.fillPath()
context.restoreGState()

// Barras de sonido dentro de la isla
let heights: [CGFloat] = [62, 118, 84, 138, 72]
let barWidth: CGFloat = 30, gap: CGFloat = 24
let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
let centerY = bottom + islandHeight / 2 - 8
NSColor.white.setFill()
for (index, height) in heights.enumerated() {
    let x = (CGFloat(size) - total) / 2 + CGFloat(index) * (barWidth + gap)
    NSBezierPath(
        roundedRect: CGRect(x: x, y: centerY - height / 2, width: barWidth, height: height),
        xRadius: barWidth / 2,
        yRadius: barWidth / 2
    ).fill()
}
NSGraphicsContext.restoreGraphicsState()

let fileManager = FileManager.default
let iconset = "AppIcon.iconset"
try? fileManager.removeItem(atPath: iconset)
try fileManager.createDirectory(atPath: iconset, withIntermediateDirectories: true)
let master = "\(iconset)/icon_512x512@2x.png"
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: master))

func run(_ tool: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
}
for points in [16, 32, 128, 256, 512] {
    try run("/usr/bin/sips", ["-z", "\(points)", "\(points)", master, "--out", "\(iconset)/icon_\(points)x\(points).png"])
    if points < 512 {
        try run("/usr/bin/sips", ["-z", "\(points * 2)", "\(points * 2)", master, "--out", "\(iconset)/icon_\(points)x\(points)@2x.png"])
    }
}
try run("/usr/bin/iconutil", ["-c", "icns", iconset, "-o", "AppIcon.icns"])
try fileManager.removeItem(atPath: iconset)
