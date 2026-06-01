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

            let color = tint ?? .black
            color.setFill()
            color.setStroke()

            // Slim vane with a knocked-out central vein (even-odd), so it reads
            // as a feather rather than a leaf.
            let feather = NSBezierPath()
            feather.windingRule = .evenOdd
            // Outer blade — slim, pointed at the top, tapering to the base.
            feather.move(to: NSPoint(x: 50, y: 20))
            feather.curve(to: NSPoint(x: 50, y: 90),
                          controlPoint1: NSPoint(x: 33, y: 42),
                          controlPoint2: NSPoint(x: 41, y: 78))
            feather.curve(to: NSPoint(x: 50, y: 20),
                          controlPoint1: NSPoint(x: 59, y: 78),
                          controlPoint2: NSPoint(x: 67, y: 42))
            feather.close()
            // Central vein (becomes a hole under even-odd).
            feather.appendRect(NSRect(x: 48.5, y: 28, width: 3, height: 54))
            feather.fill()

            // Quill: the tail below the vane — the feather's tell. (Kept below the
            // blade so it doesn't fill in the vein gap above.)
            let quill = NSBezierPath()
            quill.move(to: NSPoint(x: 50, y: 24))
            quill.line(to: NSPoint(x: 50, y: 6))
            quill.lineWidth = 4
            quill.lineCapStyle = .round
            quill.stroke()
            ctx.restoreGState()
            return true
        }
        img.isTemplate = (tint == nil)
        return img
    }
}
