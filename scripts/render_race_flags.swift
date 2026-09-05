// Run from the repository root on macOS: swift scripts/render_race_flags.swift
// Bundle the catalog's original country emoji so race rows don't depend on an installed emoji font.
// Regenerate after adding a country or changing its name in RaceCatalog.
import AppKit

let assetRoot = URL(fileURLWithPath: "Momentum/Resources/Assets.xcassets", isDirectory: true)
let catalog = try String(contentsOfFile: "Momentum/Engines/RaceCatalog.swift", encoding: .utf8)
let pattern = #/country: "([^"]+)", flag: "([^"]+)"/#
var flags: [String: String] = [:]
for match in catalog.matches(of: pattern) {
    let country = String(match.1)
    let glyph = String(match.2)
    precondition(flags[country] == nil || flags[country] == glyph, "Conflicting flags for \(country)")
    flags[country] = glyph
}
precondition(!flags.isEmpty, "No country flags found in RaceCatalog.")
guard let font = NSFont(name: "AppleColorEmoji", size: 75) else {
    fatalError("Apple Color Emoji must be installed to regenerate the artwork.")
}

for country in flags.keys.sorted() {
    let name = "RaceFlag-\(country)"
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
    let text = NSAttributedString(string: flags[country]!, attributes: [.font: font])
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
}
print("Rendered \(flags.count) country flags from RaceCatalog.")
