#!/usr/bin/env swift
// Renders the DiagnoMac app icon into the asset catalog at every size macOS needs.
// Usage: swift scripts/make-icon.swift
import AppKit

let output = URL(fileURLWithPath: "DiagnoMac/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws the icon on a 1024-point canvas, following Apple's macOS grid (824-pt body, 100-pt margin).
func drawIcon(in ctx: CGContext) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // Drop shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x1B2FA6))
    ctx.fillPath()
    ctx.restoreGState()

    // Cobalt body gradient.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(0x4A6BFF), color(0x2844D2), color(0x16248F)] as CFArray,
                              locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Faint monitor grid, like an oscilloscope screen.
    ctx.setStrokeColor(color(0xFFFFFF, 0.08))
    ctx.setLineWidth(6)
    for i in 1..<6 {
        let p = 100 + CGFloat(i) * 824 / 6
        ctx.move(to: CGPoint(x: p, y: 100)); ctx.addLine(to: CGPoint(x: p, y: 924))
        ctx.move(to: CGPoint(x: 100, y: p)); ctx.addLine(to: CGPoint(x: 924, y: p))
    }
    ctx.strokePath()

    // Soft top sheen.
    let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    // Heartbeat trace. Points are on a 30-unit grid with y pointing down, matching the prototype's logo.
    let trace: [(CGFloat, CGFloat)] = [(3, 16), (10, 16), (12.5, 9.5), (16.5, 21.5), (19, 16), (27, 16)]
    let path = CGMutablePath()
    for (i, (x, y)) in trace.enumerated() {
        let point = CGPoint(x: 100 + x / 30 * 824, y: 924 - y / 30 * 824)
        i == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    // Glow, then the crisp line on top.
    ctx.setShadow(offset: .zero, blur: 36, color: color(0xA9C0FF, 0.9))
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.setLineWidth(64)
    ctx.addPath(path)
    ctx.strokePath()
    ctx.restoreGState()

    // Hairline edge so the icon reads on dark Docks.
    ctx.addPath(shape)
    ctx.setStrokeColor(color(0xFFFFFF, 0.14))
    ctx.setLineWidth(4)
    ctx.strokePath()
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    ctx.interpolationQuality = .high
    drawIcon(in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: pixels).write(to: output.appending(path: name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appending(path: "Contents.json"))
try #"{"info":{"author":"xcode","version":1}}"#.write(
    to: output.deletingLastPathComponent().appending(path: "Contents.json"), atomically: true, encoding: .utf8)
print("Wrote \(images.count) icon images to \(output.path)")
