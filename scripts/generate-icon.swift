#!/usr/bin/env swift
//
//  generate-icon.swift
//  proximiPlay
//
//  Generates the app icon masters at 1024×1024. Re-run to regenerate:
//      swift scripts/generate-icon.swift
//
//  Design direction: ProximiPlay is *proximity* + *play* — a local party
//  game where nearby phones find each other with no internet and no
//  accounts. Every variant below is built from that one metaphor: players
//  (coloured dots, drawn from the app's own PlayerColor palette) gathered
//  around a shared centre.
//
//  Target is iOS 17, so the classic flat-icon path applies and a soft
//  radial glow is fine. Deliberately still avoids baked specular highlights
//  and rounded corners: the system masks the shape, and staying flat keeps
//  this usable as Icon Composer layer source if the target ever moves to
//  iOS 26+.
//
//  Every colour is a parameter. That is load-bearing for the tinted
//  variant, which must be strictly grayscale — iOS overlays the user's tint
//  on it, so any baked colour renders wrong.
//

import AppKit
import CoreGraphics
import Foundation

let size: CGFloat = 1024

// MARK: - Palette

struct Palette {
    let backgroundTop: NSColor
    let backgroundBottom: NSColor
    /// Glow behind the mark. `nil` disables it.
    let glow: NSColor?
    /// The host / centre mark.
    let center: NSColor
    /// Player dots, drawn in order around the ring.
    let players: [NSColor]
    /// Proximity arcs and connectors.
    let structure: NSColor

    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// Light (default) appearance — indigo/violet, matching the app's
    /// in-product accent (`Color.indigo`) so the icon and the UI read as
    /// one product.
    static let light = Palette(
        backgroundTop: rgb(88, 60, 220),
        backgroundBottom: rgb(46, 26, 138),
        glow: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16),
        center: .white,
        players: [rgb(255, 214, 10), rgb(52, 199, 89), rgb(255, 105, 97), rgb(90, 200, 250), rgb(255, 149, 0)],
        structure: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92)
    )

    /// Dark appearance — deeper field so the mark keeps its punch against a
    /// dark Home Screen.
    static let dark = Palette(
        backgroundTop: rgb(42, 28, 110),
        backgroundBottom: rgb(14, 10, 42),
        glow: NSColor(srgbRed: 0.55, green: 0.45, blue: 1, alpha: 0.22),
        center: .white,
        players: [rgb(255, 214, 10), rgb(52, 199, 89), rgb(255, 105, 97), rgb(90, 200, 250), rgb(255, 149, 0)],
        structure: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92)
    )

    /// Tinted appearance — strictly grayscale. iOS overlays the user's tint,
    /// so every channel here must be equal. Verified by `verify-tinted.swift`.
    static let tinted = Palette(
        backgroundTop: NSColor(white: 0.10, alpha: 1),
        backgroundBottom: NSColor(white: 0.02, alpha: 1),
        glow: NSColor(white: 1, alpha: 0.12),
        center: NSColor(white: 1.0, alpha: 1),
        players: [
            NSColor(white: 0.92, alpha: 1),
            NSColor(white: 0.80, alpha: 1),
            NSColor(white: 0.68, alpha: 1),
            NSColor(white: 0.56, alpha: 1),
            NSColor(white: 0.44, alpha: 1)
        ],
        structure: NSColor(white: 0.88, alpha: 1)
    )
}

// MARK: - Drawing helpers

func drawGradientBackground(_ ctx: CGContext, top: NSColor, bottom: NSColor) {
    let colors = [top.cgColor, bottom.cgColor] as CFArray
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { return }
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: size, y: 0),
        options: []
    )
}

func drawRadialGlow(_ ctx: CGContext, center: CGPoint, radius: CGFloat, color: NSColor) {
    let colors = [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { return }
    ctx.drawRadialGradient(
        gradient,
        startCenter: center, startRadius: 0,
        endCenter: center, endRadius: radius,
        options: []
    )
}

func fillCircle(_ ctx: CGContext, center: CGPoint, radius: CGFloat, color: NSColor) {
    ctx.setFillColor(color.cgColor)
    ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
}

/// One proximity arc — the "nearby devices" idea, drawn as a broad band so
/// it survives at 60 px where a thin stroke would disappear.
func strokeArc(
    _ ctx: CGContext,
    center: CGPoint,
    radius: CGFloat,
    lineWidth: CGFloat,
    startAngle: CGFloat,
    endAngle: CGFloat,
    color: NSColor
) {
    ctx.setStrokeColor(color.cgColor)
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)
    ctx.beginPath()
    ctx.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
    ctx.strokePath()
}

func strokeLine(_ ctx: CGContext, from: CGPoint, to: CGPoint, width: CGFloat, color: NSColor) {
    ctx.setStrokeColor(color.cgColor)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.beginPath()
    ctx.move(to: from)
    ctx.addLine(to: to)
    ctx.strokePath()
}

// MARK: - Variants

/// A: Players ringed around a shared centre, each linked to it.
/// The host-and-joiners topology the app actually uses, stated literally.
func drawPlayerRing(_ ctx: CGContext, _ p: Palette) {
    drawGradientBackground(ctx, top: p.backgroundTop, bottom: p.backgroundBottom)
    let mid = CGPoint(x: size / 2, y: size / 2)
    if let glow = p.glow { drawRadialGlow(ctx, center: mid, radius: size * 0.46, color: glow) }

    let orbit = size * 0.27
    let dotRadius = size * 0.085
    let count = p.players.count

    // Connectors first, so the dots sit on top of them.
    for index in 0..<count {
        let angle = (CGFloat(index) / CGFloat(count)) * 2 * .pi - .pi / 2
        let point = CGPoint(x: mid.x + cos(angle) * orbit, y: mid.y + sin(angle) * orbit)
        strokeLine(ctx, from: mid, to: point, width: size * 0.026, color: p.structure.withAlphaComponent(0.55))
    }

    for index in 0..<count {
        let angle = (CGFloat(index) / CGFloat(count)) * 2 * .pi - .pi / 2
        let point = CGPoint(x: mid.x + cos(angle) * orbit, y: mid.y + sin(angle) * orbit)
        fillCircle(ctx, center: point, radius: dotRadius, color: p.players[index])
    }

    fillCircle(ctx, center: mid, radius: size * 0.105, color: p.center)
}

/// B: Proximity arcs radiating over a cluster of players — leans on the
/// name (Proximi-) and the "found each other nearby" moment.
func drawProximityArcs(_ ctx: CGContext, _ p: Palette) {
    drawGradientBackground(ctx, top: p.backgroundTop, bottom: p.backgroundBottom)
    let origin = CGPoint(x: size / 2, y: size * 0.30)
    if let glow = p.glow { drawRadialGlow(ctx, center: origin, radius: size * 0.52, color: glow) }

    // A single broad arc — players gathered in a semicircle around the
    // device in the middle, the way people actually sit around a phone.
    // Deliberately *one* arc, not three: three concentric arcs read as the
    // system Wi-Fi glyph, which says "connectivity", not "party game".
    strokeArc(
        ctx,
        center: origin,
        radius: size * 0.30,
        lineWidth: size * 0.05,
        startAngle: .pi / 7,
        endAngle: .pi * 6 / 7,
        color: p.structure.withAlphaComponent(0.42)
    )

    // Players seated along the arc.
    let seats: [CGFloat] = [.pi / 7, .pi * 2.2 / 7, .pi * 3.5 / 7, .pi * 4.8 / 7, .pi * 6 / 7]
    for (index, angle) in seats.enumerated() {
        let point = CGPoint(x: origin.x + cos(angle) * size * 0.30, y: origin.y + sin(angle) * size * 0.30)
        fillCircle(ctx, center: point, radius: size * 0.072, color: p.players[index])
    }

    // The shared device they're gathered around.
    fillCircle(ctx, center: origin, radius: size * 0.098, color: p.center)
}

/// C: A bold play triangle assembled from player dots — "play", stated as
/// directly as possible, with the multiplayer idea inside the shape.
func drawPlayMark(_ ctx: CGContext, _ p: Palette) {
    drawGradientBackground(ctx, top: p.backgroundTop, bottom: p.backgroundBottom)
    let mid = CGPoint(x: size / 2, y: size / 2)
    if let glow = p.glow { drawRadialGlow(ctx, center: mid, radius: size * 0.44, color: glow) }

    // Rounded play triangle, nudged right so it reads optically centred.
    let cx = size * 0.535
    let r = size * 0.235
    // `addArc(tangent1End:tangent2End:radius:)` needs a current point to
    // work from — without a `move(to:)` first, the whole path stays empty
    // and the mark silently doesn't render.
    let corners = (0..<3).map { index -> CGPoint in
        let angle = (CGFloat(index) / 3) * 2 * .pi
        return CGPoint(x: cx + cos(angle) * r, y: mid.y + sin(angle) * r)
    }
    let path = CGMutablePath()
    path.move(to: CGPoint(x: (corners[0].x + corners[2].x) / 2, y: (corners[0].y + corners[2].y) / 2))
    for index in 0..<3 {
        path.addArc(
            tangent1End: corners[index],
            tangent2End: corners[(index + 1) % 3],
            radius: size * 0.085
        )
    }
    path.closeSubpath()
    ctx.setFillColor(p.center.cgColor)
    ctx.addPath(path)
    ctx.fillPath()

    // Players orbiting the mark.
    let orbit = size * 0.365
    let angles: [CGFloat] = [.pi * 0.78, .pi * 1.0, .pi * 1.22]
    for (index, angle) in angles.enumerated() {
        let point = CGPoint(x: size / 2 + cos(angle) * orbit, y: mid.y + sin(angle) * orbit)
        fillCircle(ctx, center: point, radius: size * 0.062, color: p.players[index])
    }
}

// MARK: - Render

func render(_ name: String, _ draw: (CGContext, Palette) -> Void, _ palette: Palette, into directory: String) {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
            data: nil,
            width: Int(size),
            height: Int(size),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
          ) else {
        print("Failed to create context for \(name)")
        return
    }

    draw(ctx, palette)

    guard let image = ctx.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }

    let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
    try? data.write(to: url)
    print("Wrote \(url.path)")
}

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-variants"
try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

let variants: [(String, (CGContext, Palette) -> Void)] = [
    ("a-player-ring", drawPlayerRing),
    ("b-proximity-arcs", drawProximityArcs),
    ("c-play-mark", drawPlayMark)
]

// Every variant in every appearance, so the tinted and dark renders can be
// judged before one is chosen rather than after.
for (name, draw) in variants {
    render("\(name)-light", draw, .light, into: outputDirectory)
    render("\(name)-dark", draw, .dark, into: outputDirectory)
    render("\(name)-tinted", draw, .tinted, into: outputDirectory)
}
