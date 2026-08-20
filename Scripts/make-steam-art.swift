#!/usr/bin/env swift
// Generates the Steam library artwork set into Resources/steam/.
//
// Steam expects specific aspect ratios for a library tile, and a non-Steam
// shortcut with no art shows as a grey box with a filename on it. Drawn in code
// from the same palette as the app icon so the tile matches what launches.

import AppKit
import Foundation

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/steam")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let canvas = NSColor(srgbRed: 0.059, green: 0.059, blue: 0.059, alpha: 1)
let brand  = NSColor(srgbRed: 1.000, green: 0.000, blue: 0.000, alpha: 1)

/// Play badge + wordmark, centred, scaled to the smaller dimension.
func draw(width: CGFloat, height: CGFloat, showWordmark: Bool, transparent: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(x: 0, y: 0, width: width, height: height)
    if !transparent {
        canvas.setFill()
        rect.fill()
        // A faint vertical lift keeps a large flat tile from looking dead.
        NSGradient(colors: [
            NSColor(white: 1, alpha: 0.05),
            NSColor(white: 0, alpha: 0.0)
        ])?.draw(in: rect, angle: 90)
    }

    let unit = min(width, height)
    let badgeW = unit * 0.42
    let badgeH = badgeW * 0.70
    let centreY = showWordmark ? rect.midY + unit * 0.09 : rect.midY
    let badge = NSRect(x: rect.midX - badgeW / 2, y: centreY - badgeH / 2,
                       width: badgeW, height: badgeH)

    brand.setFill()
    NSBezierPath(roundedRect: badge, xRadius: badgeH * 0.26, yRadius: badgeH * 0.26).fill()

    let triW = badgeH * 0.42, triH = badgeH * 0.48
    let tri = NSBezierPath()
    tri.move(to: NSPoint(x: badge.midX - triW * 0.42, y: badge.midY + triH / 2))
    tri.line(to: NSPoint(x: badge.midX + triW * 0.58, y: badge.midY))
    tri.line(to: NSPoint(x: badge.midX - triW * 0.42, y: badge.midY - triH / 2))
    tri.close()
    NSColor.white.setFill()
    tri.fill()

    if showWordmark {
        let text = "YouTube" as NSString
        let size = unit * 0.13
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let measured = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: rect.midX - measured.width / 2,
                              y: badge.minY - measured.height - unit * 0.06),
                  withAttributes: attributes)
    }

    return image
}

let variants: [(name: String, w: CGFloat, h: CGFloat, wordmark: Bool, transparent: Bool)] = [
    ("grid.png",     460,  215, true,  false),   // small capsule
    ("portrait.png", 600,  900, true,  false),   // library portrait
    ("hero.png",    1920,  620, false, false),   // library header
    ("logo.png",     640,  360, true,  true),    // overlay logo, transparent
    ("icon.png",     256,  256, false, false)    // shortcut icon
]

for variant in variants {
    let image = draw(width: variant.w, height: variant.h,
                     showWordmark: variant.wordmark, transparent: variant.transparent)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("failed to encode \(variant.name)\n".data(using: .utf8)!)
        exit(1)
    }
    try png.write(to: outDir.appendingPathComponent(variant.name))
}

print("wrote \(variants.count) Steam art files to \(outDir.path)")
