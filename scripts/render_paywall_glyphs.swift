// Run on macOS: swift scripts/render_paywall_glyphs.swift
// Freeze the existing flag/apple illustrations into transparent assets. This keeps the
// paywall artwork independent of the device's emoji font and its fallback renderer.
import AppKit

let assetRoot = URL(fileURLWithPath: "Momentum/Resources/Assets.xcassets", isDirectory: true)
guard let font = NSFont(name: "AppleColorEmoji", size: 75) else {
    fatalError("Apple Color Emoji must be installed to regenerate the artwork.")
}

for (name, glyph) in [("PaywallRaceFlag", "🏁"), ("PaywallFuelApple", "🍎")] {
    let directory = assetRoot.appendingPathComponent("\(name).imageset", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 90, pixelsHigh: 90,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0),
          let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Could not create the artwork canvas.")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .high
    let text = NSAttributedString(string: glyph, attributes: [.font: font])
    let size = text.size()
    text.draw(at: NSPoint(x: (90 - size.width) / 2, y: (90 - size.height) / 2))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode \(name).")
    }
    try png.write(to: directory.appendingPathComponent("artwork.png"))
    let manifest = """
    {
      "images": [{ "filename": "artwork.png", "idiom": "universal" }],
      "info": { "author": "xcode", "version": 1 },
      "properties": { "template-rendering-intent": "original" }
    }
    """
    try manifest.write(to: directory.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    print("Rendered \(name)")
}
