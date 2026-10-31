import AppKit

/// The app icon's planet and orbit for the menu bar, drawn white so it works as a template image.
/// Mirrors `scripts/icon.swift` on a 24-unit grid; the used arc is opaque and the rest dimmed, since a template has no color.
enum OrbitIcon {
    /// Point on the orbit (an ellipse tilted 20 degrees) at parameter t, flipped to AppKit's y-up space.
    private static func orbit(_ t: CGFloat) -> NSPoint {
        let (a, b, tilt): (CGFloat, CGFloat, CGFloat) = (10.6, 4.7, -20 * .pi / 180)
        let (x, y) = (a * cos(t), b * sin(t))
        return NSPoint(x: 12 + x * cos(tilt) - y * sin(tilt), y: 12 - (x * sin(tilt) + y * cos(tilt)))
    }

    private static func arc(from: CGFloat, to: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: orbit(from))
        for i in 1...100 { path.line(to: orbit(from + (to - from) * CGFloat(i) / 100)) }
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        return path
    }

    static func draw(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scale(by: rect.width / 24)
        transform.concat()

        let dim = NSColor.white.withAlphaComponent(0.45)
        dim.setStroke()
        arc(from: 0, to: 2 * .pi).stroke()
        let planet = NSBezierPath(ovalIn: NSRect(x: 9.1, y: 9.1, width: 5.8, height: 5.8))
        planet.lineWidth = 1.6
        planet.stroke()

        // Same used share as the app icon: from the far left, clockwise over the top.
        let start = CGFloat.pi, used = 1.3 * CGFloat.pi
        NSColor.white.setStroke()
        arc(from: start, to: start + used).stroke()
        let tip = orbit(start + used)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: tip.x - 2, y: tip.y - 2, width: 4, height: 4)).fill()
    }
}
