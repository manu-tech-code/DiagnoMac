#!/usr/bin/env swift
// Renders the DiagnoMac app icon into the asset catalog at every size macOS needs.
// Usage: swift scripts/make-icon.swift
//
// The Score Ring: the health-score ring from the Overview, 86% full, with the pulse inside.
// Drawn on Apple's 1024 grid (824-point body, 100-point margin). The concepts it was picked
// from are in prototype/icon-concepts.html.
import AppKit

let output = URL(fileURLWithPath: "DiagnoMac/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

/// Core Graphics has y pointing up; the design was drawn with y pointing down.
func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: 1024 - y) }

func drawIcon(in ctx: CGContext) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.32))
    ctx.addPath(shape)
    ctx.setFillColor(color(0xE3E9F6))
    ctx.fillPath()
    ctx.restoreGState()

    // A white tile that cools to pale blue at the bottom.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0xFFFFFF), color(0xE3E9F6)], [0, 1]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    let center = p(512, 512)
    let radius: CGFloat = 250

    // The ring's track.
    ctx.setLineWidth(88)
    ctx.setStrokeColor(color(0xD8E0F0))
    ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    ctx.strokePath()

    // The score: 86% of the ring, clockwise from the top, in the cobalt gradient.
    ctx.saveGState()
    let start = CGFloat.pi / 2
    ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: start - 0.86 * 2 * .pi, clockwise: true)
    ctx.setLineWidth(88)
    ctx.setLineCap(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0x5C7CFF), color(0x16248F)], [0, 1]),
                           start: p(262, 262), end: p(762, 762), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // The pulse inside the ring.
    let pulse = [p(372, 512), p(452, 512), p(482, 436), p(538, 594), p(566, 512), p(652, 512)]
    ctx.setStrokeColor(color(0x2844D2))
    ctx.setLineWidth(36)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addLines(between: pulse)
    ctx.strokePath()

    // Hairline edge so the light tile holds its shape on a light Dock.
    ctx.addPath(shape)
    ctx.setStrokeColor(color(0x000000, 0.06))
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
