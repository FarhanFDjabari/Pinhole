//
//  make-icon.swift — draws Pinhole's app icon and writes PinholeMenuBar/Pinhole.icns.
//
//  Run via scripts/make-icon.sh. Regenerate only when the artwork changes; the
//  .icns is checked in so an ordinary build does not depend on this.
//
//  Motif: a pinhole. Light enters through a single bright point and fans out
//  below it as the test pattern's colour bars — the whole project in one shape,
//  and still readable at 16pt where the fan is the only thing left.
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

let rgb = CGColorSpace(name: CGColorSpace.sRGB)!

guard let context = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
    space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("cannot create context") }

let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let shape = CGPath(roundedRect: body, cornerWidth: corner, cornerHeight: corner, transform: nil)

context.saveGState()
context.addPath(shape)
context.clip()

// Base: deep slate, so the light cone carries all the colour.
let base = CGGradient(
    colorsSpace: rgb,
    colors: [NSColor(srgbRed: 0.13, green: 0.15, blue: 0.24, alpha: 1).cgColor,
             NSColor(srgbRed: 0.04, green: 0.04, blue: 0.08, alpha: 1).cgColor] as CFArray,
    locations: [0, 1])!
context.drawLinearGradient(base,
                           start: CGPoint(x: 0, y: size),
                           end: CGPoint(x: size, y: 0),
                           options: [])

// The aperture, and the cone of light thrown from it.
let apex = CGPoint(x: body.midX, y: body.maxY - body.height * 0.24)
let spread: CGFloat = 108 * .pi / 180        // full opening angle
let reach = body.height * 1.4                // past the bottom edge; clipping trims it
let start = -.pi / 2 - spread / 2            // fans downward from the apex

for (index, color) in bars.enumerated() {
    let from = start + spread * CGFloat(index) / CGFloat(bars.count)
    let to = start + spread * CGFloat(index + 1) / CGFloat(bars.count)
    context.beginPath()
    context.move(to: apex)
    context.addLine(to: CGPoint(x: apex.x + cos(from) * reach, y: apex.y + sin(from) * reach))
    context.addLine(to: CGPoint(x: apex.x + cos(to) * reach, y: apex.y + sin(to) * reach))
    context.closePath()
    context.setFillColor(color.withAlphaComponent(0.95).cgColor)
    context.fillPath()
}

// Light loses itself with distance: fade the cone back into the plate.
let falloff = CGGradient(
    colorsSpace: rgb,
    colors: [NSColor(srgbRed: 0.04, green: 0.04, blue: 0.08, alpha: 0.68).cgColor,
             NSColor(srgbRed: 0.04, green: 0.04, blue: 0.08, alpha: 0).cgColor] as CFArray,
    locations: [0, 1])!
context.drawLinearGradient(falloff,
                           start: CGPoint(x: 0, y: body.minY),
                           end: CGPoint(x: 0, y: apex.y - body.height * 0.16),
                           options: [])

// The hole itself: a hot core with a halo, drawn over the cone it emits.
let halo = CGGradient(
    colorsSpace: rgb,
    colors: [NSColor.white.withAlphaComponent(0.72).cgColor,
             NSColor.white.withAlphaComponent(0.0).cgColor] as CFArray,
    locations: [0, 1])!
context.drawRadialGradient(halo,
                           startCenter: apex, startRadius: 0,
                           endCenter: apex, endRadius: body.width * 0.155,
                           options: [])

context.setFillColor(NSColor.white.cgColor)
let core = body.width * 0.055
context.fillEllipse(in: CGRect(x: apex.x - core, y: apex.y - core, width: core * 2, height: core * 2))

context.restoreGState()

guard let image = context.makeImage() else { fatalError("cannot render icon") }
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: size, height: size)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("cannot encode") }
try png.write(to: out)
print("wrote \(out.path)")
