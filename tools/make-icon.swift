#!/usr/bin/env swift
// Regenerates Resources/AppIcon.icns: a white tray glyph on a black squircle.
// Usage: swift tools/make-icon.swift [output.icns]

import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"
let sizes = [16, 32, 64, 128, 256, 512, 1024]

func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    let result = NSImage(size: image.size)
    result.lockFocus()
    image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    color.set()
    NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
    result.unlockFocus()
    return result
}

func icon(size: Int) -> Data? {
    let side = CGFloat(size)
    let canvas = NSImage(size: NSSize(width: side, height: side))
    canvas.lockFocus()

    NSColor.black.setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: side, height: side),
                 xRadius: side * 0.22, yRadius: side * 0.22).fill()
    NSColor(white: 1, alpha: 0.14).setStroke()
    let border = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: side - 1, height: side - 1),
                              xRadius: side * 0.22, yRadius: side * 0.22)
    border.lineWidth = max(1, side / 256)
    border.stroke()

    let config = NSImage.SymbolConfiguration(pointSize: side * 0.52, weight: .regular)
    if let symbol = NSImage(systemSymbolName: "tray.full.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let glyph = tinted(symbol, .white)
        let box = NSRect(
            x: (side - glyph.size.width) / 2,
            y: (side - glyph.size.height) / 2,
            width: glyph.size.width,
            height: glyph.size.height
        )
        glyph.draw(in: box)
    }

    canvas.unlockFocus()
    guard let tiff = canvas.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff)
    else { return nil }
    bitmap.size = NSSize(width: side, height: side)
    return bitmap.representation(using: .png, properties: [:])
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for size in sizes {
    guard let png = icon(size: size) else { fatalError("failed to render \(size)pt icon") }
    let base = size <= 512 ? size : 512
    let name = size == 1024 ? "icon_512x512@2x.png" : "icon_\(base)x\(base).png"
    try png.write(to: iconset.appendingPathComponent(name))
    // Retina variants reuse the next size up.
    if size >= 32, size <= 512 {
        let half = size / 2
        try png.write(to: iconset.appendingPathComponent("icon_\(half)x\(half)@2x.png"))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Wrote \(output)" : "iconutil failed")
exit(iconutil.terminationStatus)
