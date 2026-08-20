#!/usr/bin/env swift
// Generates the app icon as an .iconset directory, which `iconutil` then turns
// into Resources/YouTubeTV.icns (see `just icon`).
//
// The icon is drawn in code rather than checked in as art so it stays in step
// with Theme.swift's palette — the same near-black canvas and YouTube red the
// leanback UI uses. The .icns output IS committed, because rasterizing needs
// AppKit and a build machine without a window server would fail at exactly the
// wrong moment.

import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count > 1 else {
    FileHandle.standardError.write("usage: make-icon.swift <output.iconset>\n".data(using: .utf8)!)
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// Kept in sync with Theme.swift.
let canvas = NSColor(srgbRed: 0.059, green: 0.059, blue: 0.059, alpha: 1)   // #0F0F0F
let brand  = NSColor(srgbRed: 1.000, green: 0.000, blue: 0.000, alpha: 1)   // #FF0000

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(x: 0, y: 0, width: size, height: size)

    // macOS icons are squircles inset from their canvas; ~18% corner radius on a
    // ~82% inset square is the proportion Apple's own icons use closely enough
    // that this doesn't look foreign in the Dock.
    let inset = size * 0.09
    let body = rect.insetBy(dx: inset, dy: inset)
    let squircle = NSBezierPath(roundedRect: body,
                                xRadius: body.width * 0.22,
                                yRadius: body.width * 0.22)
    canvas.setFill()
    squircle.fill()

    // Rounded "play badge": a wide rounded rect with a white triangle punched in,
    // which is the silhouette the TV client's own splash uses.
    let badgeW = body.width * 0.62
    let badgeH = badgeW * 0.70
    let badge = NSRect(x: body.midX - badgeW / 2,
                       y: body.midY - badgeH / 2,
                       width: badgeW,
                       height: badgeH)
    brand.setFill()
    NSBezierPath(roundedRect: badge,
                 xRadius: badgeH * 0.26,
                 yRadius: badgeH * 0.26).fill()

    let triW = badgeH * 0.42
    let triH = badgeH * 0.48
    let tri = NSBezierPath()
    tri.move(to: NSPoint(x: badge.midX - triW * 0.42, y: badge.midY + triH / 2))
    tri.line(to: NSPoint(x: badge.midX + triW * 0.58, y: badge.midY))
    tri.line(to: NSPoint(x: badge.midX - triW * 0.42, y: badge.midY - triH / 2))
    tri.close()
    NSColor.white.setFill()
    tri.fill()

    return image
}

// The exact filenames iconutil requires.
let variants: [(name: String, px: CGFloat)] = [
    ("icon_16x16.png", 16),      ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),      ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),   ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),   ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),   ("icon_512x512@2x.png", 1024),
]

for variant in variants {
    let image = drawIcon(size: variant.px)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("failed to encode \(variant.name)\n".data(using: .utf8)!)
        exit(1)
    }
    try png.write(to: outDir.appendingPathComponent(variant.name))
}

print("wrote \(variants.count) images to \(outDir.path)")
