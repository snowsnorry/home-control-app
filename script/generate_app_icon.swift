#!/usr/bin/env swift
import AppKit

// Render every size from the same native symbol, rather than downsampling a bitmap.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("build/AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

guard let symbol = NSImage(systemSymbolName: "house.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: 600, weight: .regular)) else {
    fatalError("The house symbol is unavailable.")
}

func render(pixels: Int, filename: String) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Could not create the icon bitmap.")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    let canvas = NSRect(x: 0, y: 0, width: 1024, height: 1024)
    let scale = CGFloat(pixels) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)
    context.cgContext.clear(canvas)
    context.imageInterpolation = .high

    let tile = NSBezierPath(roundedRect: canvas.insetBy(dx: 64, dy: 64), xRadius: 190, yRadius: 190)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor(srgbRed: 0.13, green: 0.36, blue: 0.80, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    let gradient = NSGradient(starting: NSColor(srgbRed: 0.10, green: 0.53, blue: 0.99, alpha: 1),
        ending: NSColor(srgbRed: 0.13, green: 0.32, blue: 0.77, alpha: 1))!
    gradient.draw(in: tile, angle: -90)
    NSColor.white.withAlphaComponent(0.18).setStroke()
    tile.lineWidth = 2
    tile.stroke()

    let symbolScale = min(600 / symbol.size.width, 600 / symbol.size.height)
    let size = NSSize(width: symbol.size.width * symbolScale, height: symbol.size.height * symbolScale)
    let symbolRect = NSRect(x: (1024 - size.width) / 2, y: (1024 - size.height) / 2 + 8,
        width: size.width, height: size.height)
    context.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
    symbol.draw(in: symbolRect)
    NSColor.white.setFill()
    canvas.fill(using: .sourceIn)
    context.cgContext.endTransparencyLayer()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode the icon.")
    }
    try png.write(to: iconset.appendingPathComponent(filename))
}

for points in [16, 32, 128, 256, 512] {
    try render(pixels: points, filename: "icon_\(points)x\(points).png")
    try render(pixels: points * 2, filename: "icon_\(points)x\(points)@2x.png")
}

let converter = Process()
converter.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
converter.arguments = ["--convert", "icns", "--output",
    root.appendingPathComponent("HomeControl/Resources/AppIcon.icns").path, iconset.path]
try converter.run()
converter.waitUntilExit()
guard converter.terminationStatus == 0 else { fatalError("iconutil could not create AppIcon.icns.") }
print("Created HomeControl/Resources/AppIcon.icns")
