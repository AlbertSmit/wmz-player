#!/usr/bin/env swift
// Rasterises an Icon Composer document (.icon) into the .icns an app bundle
// needs. Usage: swift scripts/make-icon.swift Resources/AppIcon.icon Resources/AppIcon.icns
import AppKit
import CoreGraphics

guard CommandLine.arguments.count >= 3 else {
    print("usage: make-icon.swift <AppIcon.icon> <out.icns>")
    exit(1)
}

let iconPath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]
let glyphPath = iconPath + "/Assets/SVG Image.svg"
let iconset = NSTemporaryDirectory() + "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

// From the document's icon.json: automatic-gradient in display-P3.
let base = CGColor(srgbRed: 0.573, green: 0.513, blue: 0.968, alpha: 1)
let top = CGColor(srgbRed: 0.66, green: 0.60, blue: 0.99, alpha: 1)
let bottom = CGColor(srgbRed: 0.52, green: 0.46, blue: 0.94, alpha: 1)

func render(size: Int) -> CGImage? {
    let canvas = CGFloat(size)
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let inset = canvas * 0.1
    let rect = CGRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
    let radius = rect.width * 0.225
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: rect.maxY),
                           end: CGPoint(x: 0, y: rect.minY),
                           options: [])

    guard let glyph = NSImage(contentsOfFile: glyphPath) else { return ctx.makeImage() }
    var glyphRect = CGRect(origin: .zero, size: glyph.size)
    guard let glyphCG = glyph.cgImage(forProposedRect: &glyphRect, context: nil, hints: nil) else {
        return ctx.makeImage()
    }
    let width = canvas * 0.76
    let height = width * CGFloat(glyphCG.height) / CGFloat(glyphCG.width)
    let target = CGRect(x: (canvas - width) / 2,
                        y: (canvas - height) / 2 + canvas * 0.012,
                        width: width, height: height)
    ctx.saveGState()
    ctx.clip(to: target, mask: glyphCG)
    ctx.setFillColor(CGColor(srgbRed: 0.06, green: 0.05, blue: 0.12, alpha: 1))
    ctx.fill(target)
    ctx.restoreGState()
    _ = base
    return ctx.makeImage()
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    guard let image = render(size: size) else { continue }
    func write(_ name: String) {
        let url = URL(fileURLWithPath: iconset).appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
    write("icon_\(size)x\(size).png")
    if size > 16 { write("icon_\(size / 2)x\(size / 2)@2x.png") }
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset, "-o", outputPath]
try! task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    print("iconutil failed")
    exit(1)
}
print("wrote \(outputPath)")
