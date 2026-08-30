//
//  make-icon.swift — draws SimCam's app icon and writes SimCamMenuBar/SimCam.icns.
//
//  Run via scripts/make-icon.sh. Regenerate only when the artwork changes; the
//  .icns is checked in so an ordinary build does not depend on this.
//
//  Motif: the test pattern's colour bars behind a video glyph — the fake camera,
//  in one picture.
//

import AppKit
import Foundation

let size: CGFloat = 1024
let inset: CGFloat = 92          // macOS icons sit inside their canvas
let corner: CGFloat = 200

let bars: [NSColor] = [
    .init(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1),
    .init(srgbRed: 0.95, green: 0.85, blue: 0.20, alpha: 1),
    .init(srgbRed: 0.20, green: 0.82, blue: 0.85, alpha: 1),
    .init(srgbRed: 0.25, green: 0.78, blue: 0.35, alpha: 1),
    .init(srgbRed: 0.85, green: 0.30, blue: 0.75, alpha: 1),
    .init(srgbRed: 0.90, green: 0.25, blue: 0.25, alpha: 1),
    .init(srgbRed: 0.25, green: 0.40, blue: 0.90, alpha: 1),
]

guard let context = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("cannot create context") }

let graphics = NSGraphicsContext(cgContext: context, flipped: false)
NSGraphicsContext.current = graphics

let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let shape = CGPath(roundedRect: body, cornerWidth: corner, cornerHeight: corner, transform: nil)

// Base: deep slate, so the bars and glyph carry the colour.
context.saveGState()
context.addPath(shape)
context.clip()

let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [NSColor(srgbRed: 0.13, green: 0.15, blue: 0.24, alpha: 1).cgColor,
             NSColor(srgbRed: 0.05, green: 0.05, blue: 0.09, alpha: 1).cgColor] as CFArray,
    locations: [0, 1])!
context.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: size),
                           end: CGPoint(x: size, y: 0),
                           options: [])

// Colour bars across the lower half, fading out upward.
let barBand = CGRect(x: body.minX, y: body.minY, width: body.width, height: body.height * 0.46)
let barWidth = barBand.width / CGFloat(bars.count)
for (index, color) in bars.enumerated() {
    context.setFillColor(color.withAlphaComponent(0.92).cgColor)
    context.fill(CGRect(x: barBand.minX + CGFloat(index) * barWidth, y: barBand.minY,
                        width: barWidth, height: barBand.height))
}
let fade = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [NSColor(srgbRed: 0.05, green: 0.05, blue: 0.09, alpha: 0).cgColor,
             NSColor(srgbRed: 0.07, green: 0.08, blue: 0.13, alpha: 1).cgColor] as CFArray,
    locations: [0, 1])!
context.drawLinearGradient(fade,
                           start: CGPoint(x: 0, y: barBand.minY),
                           end: CGPoint(x: 0, y: barBand.maxY),
                           options: [])
context.restoreGState()

// Video glyph. Tinting happens in its own transparent image first: a
// `.sourceAtop` fill straight onto the canvas would land on every opaque
// background pixel, not just the glyph.
if let symbol = NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil),
   let configured = symbol.withSymbolConfiguration(.init(pointSize: 380, weight: .semibold)) {

    let scale = min(520 / configured.size.width, 520 / configured.size.height)
    let drawn = NSSize(width: configured.size.width * scale, height: configured.size.height * scale)

    let tinted = NSImage(size: drawn)
    tinted.lockFocus()
    let glyphRect = NSRect(origin: .zero, size: drawn)
    configured.draw(in: glyphRect)
    NSColor.white.set()
    glyphRect.fill(using: .sourceAtop)
    tinted.unlockFocus()

    let origin = NSPoint(x: (size - drawn.width) / 2, y: (size - drawn.height) / 2 + 70)

    // A soft shadow keeps the glyph legible where it crosses the bright bars.
    context.setShadow(offset: CGSize(width: 0, height: -8), blur: 24,
                      color: NSColor.black.withAlphaComponent(0.45).cgColor)
    tinted.draw(in: NSRect(origin: origin, size: drawn),
                from: .zero, operation: .sourceOver, fraction: 1)
    context.setShadow(offset: .zero, blur: 0, color: nil)
}

NSGraphicsContext.current = nil

guard let image = context.makeImage() else { fatalError("cannot render icon") }
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: size, height: size)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("cannot encode") }
try png.write(to: out)
print("wrote \(out.path)")
