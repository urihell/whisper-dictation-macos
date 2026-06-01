import AppKit

extension NSColor {
    /// App accent — the indigo/violet from the app icon (matches SwiftUI Color.brand).
    static let brand = NSColor(srgbRed: 0.42, green: 0.33, blue: 0.92, alpha: 1)
}

/// Draws the menu-bar feather glyph in code (no asset needed). A feather fits
/// the app's name — a "whisper" is soft/light, and a quill = writing/dictation.
enum FeatherIcon {
    /// `tint == nil` → a template image (monochrome, adapts to the menu bar in
    /// light/dark). A tint → a solid colored glyph (used for the active state).
    static func image(tint: NSColor?) -> NSImage {
        let size = NSSize(width: 20, height: 20)
        let img = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            // Design in a 100×100 space, mapped into the icon with a slight tilt.
            let scale = min(rect.width, rect.height) / 100.0
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.rotate(by: -14.0 * .pi / 180.0)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -50, y: -50)

            let color = tint ?? .black
            color.setStroke()

            // Central shaft (rachis) + quill tail.
            let shaft = NSBezierPath()
            shaft.move(to: NSPoint(x: 50, y: 95))
            shaft.line(to: NSPoint(x: 50, y: 4))
            shaft.lineWidth = 6
            shaft.lineCapStyle = .round
            shaft.stroke()

            // Barbs sweeping up toward the tip — the herringbone that makes it
            // read as a feather (not a leaf). Length follows a leaf envelope.
            let barbs = NSBezierPath()
            barbs.lineWidth = 5
            barbs.lineCapStyle = .round
            for y: CGFloat in [30, 42, 54, 66, 78] {
                let t = Double((y - 14) / 78)            // 0…~0.8 along the blade
                let len = CGFloat(sin(Double.pi * t)) * 33
                let up = len * 0.5
                barbs.move(to: NSPoint(x: 49, y: y))
                barbs.line(to: NSPoint(x: 49 - len, y: y + up))
                barbs.move(to: NSPoint(x: 51, y: y))
                barbs.line(to: NSPoint(x: 51 + len, y: y + up))
            }
            barbs.stroke()
            ctx.restoreGState()
            return true
        }
        img.isTemplate = (tint == nil)
        return img
    }
}
