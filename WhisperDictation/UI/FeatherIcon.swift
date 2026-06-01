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
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            // Design in a 100×100 space, mapped into the icon with a slight tilt.
            let scale = min(rect.width, rect.height) / 100.0
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.rotate(by: -20.0 * .pi / 180.0)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -50, y: -50)

            // The vane (the soft blade of the feather).
            let vane = NSBezierPath()
            vane.move(to: NSPoint(x: 50, y: 12))
            vane.curve(to: NSPoint(x: 52, y: 95),
                       controlPoint1: NSPoint(x: 16, y: 44),
                       controlPoint2: NSPoint(x: 34, y: 84))
            vane.curve(to: NSPoint(x: 50, y: 12),
                       controlPoint1: NSPoint(x: 70, y: 82),
                       controlPoint2: NSPoint(x: 86, y: 40))
            vane.close()

            // The shaft + quill — only the part below the vane shows, giving the
            // feather its tell (vs. a plain leaf).
            let shaft = NSBezierPath()
            shaft.move(to: NSPoint(x: 51, y: 90))
            shaft.line(to: NSPoint(x: 49, y: 3))
            shaft.lineWidth = 5
            shaft.lineCapStyle = .round

            let color = tint ?? .black
            color.setFill()
            color.setStroke()
            vane.fill()
            shaft.stroke()
            ctx.restoreGState()
            return true
        }
        img.isTemplate = (tint == nil)
        return img
    }
}
