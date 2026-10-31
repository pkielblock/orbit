import AppKit

/// Spiral galaxy for the menu bar, drawn white so it works as a template image.
enum GalaxyIcon {
    static func draw(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scale(by: rect.width / 24)
        transform.concat()


        // Opposite arms share the same geometry, keeping the small silhouette recognizable.
        for arm in 0..<2 {
            let path = NSBezierPath()
            for step in 0...100 {
                let fraction = CGFloat(step) / 100
                let angle = fraction * .pi * 1.55 + CGFloat(arm) * .pi - .pi / 4
                let radius = 2.6 + fraction * 8
                let point = NSPoint(x: 12 + cos(angle) * radius,
                                    y: 12 + sin(angle) * radius * 0.65)
                if step == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            path.lineWidth = 2.2
            path.lineCapStyle = .round
            NSColor.white.setStroke()
            path.stroke()
        }

        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: 9.6, y: 9.6, width: 4.8, height: 4.8)).fill()
        for star in [NSRect(x: 4, y: 18, width: 1.8, height: 1.8),
                     NSRect(x: 18.5, y: 3.5, width: 1.5, height: 1.5)] {
            NSBezierPath(ovalIn: star).fill()
        }
    }
}
