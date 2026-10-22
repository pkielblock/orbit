import AppKit

/// Shared spiral galaxy artwork for the app bundle and menu bar.
enum GalaxyIcon {
    static func draw(in rect: NSRect, colored: Bool) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scale(by: rect.width / 24)
        transform.concat()

        if colored {
            let background = NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 22, height: 22), xRadius: 5, yRadius: 5)
            NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.08, blue: 0.28, alpha: 1),
                       ending: NSColor(calibratedRed: 0.02, green: 0.03, blue: 0.10, alpha: 1))!
                .draw(in: background, angle: -90)
            let inset = NSAffineTransform()
            inset.translateX(by: 3, yBy: 3)
            inset.scale(by: 0.75)
            inset.concat()
        }

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
            if colored {
                (arm == 0 ? NSColor(calibratedRed: 0.40, green: 0.78, blue: 1, alpha: 1)
                          : NSColor(calibratedRed: 0.78, green: 0.43, blue: 1, alpha: 1)).setStroke()
            } else {
                NSColor.white.setStroke()
            }
            path.stroke()
        }

        (colored ? NSColor(calibratedRed: 1, green: 0.89, blue: 0.69, alpha: 1) : .white).setFill()
        NSBezierPath(ovalIn: NSRect(x: 9.6, y: 9.6, width: 4.8, height: 4.8)).fill()
        for star in [NSRect(x: 4, y: 18, width: 1.8, height: 1.8),
                     NSRect(x: 18.5, y: 3.5, width: 1.5, height: 1.5)] {
            NSBezierPath(ovalIn: star).fill()
        }
    }
}
