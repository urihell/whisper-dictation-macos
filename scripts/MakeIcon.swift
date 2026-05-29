import AppKit

// Renders a 1024×1024 app icon: a white microphone on an indigo→violet
// rounded-rect (squircle-ish) background. Usage: swift MakeIcon.swift out.png

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high

// Background rounded rect with a small transparent margin (macOS-style).
let margin = size * 0.085
let rect = NSRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
let radius = rect.width * 0.2237
let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

let top = NSColor(srgbRed: 0.40, green: 0.40, blue: 0.96, alpha: 1)    // indigo
let bottom = NSColor(srgbRed: 0.62, green: 0.34, blue: 0.90, alpha: 1) // violet
NSGradient(starting: top, ending: bottom)?.draw(in: bg, angle: -90)

// Microphone glyph, tinted white, centered.
func tinted(_ img: NSImage, _ color: NSColor) -> NSImage {
    let out = NSImage(size: img.size)
    out.lockFocus()
    img.draw(in: NSRect(origin: .zero, size: img.size))
    color.set()
    NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}

let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .semibold)
if let base = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil),
   let mic = base.withSymbolConfiguration(cfg) {
    let white = tinted(mic, .white)
    let s = white.size
    white.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
}

image.unlockFocus()

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("icon render failed\n".utf8))
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
